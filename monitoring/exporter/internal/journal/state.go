package journal

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"time"
)

type Cursor struct {
	ID     string `json:"id"`
	Offset int64  `json:"offset"`
}
type Sample struct {
	Event
	Key      string `json:"-"`
	Fresh    bool   `json:"fresh"`
	LastSeen int64  `json:"last_seen"`
}
type image struct {
	Sequence uint64            `json:"sequence"`
	Counters map[string]Sample `json:"counters"`
	Offsets  map[string]Cursor `json:"offsets"`
}
type transaction struct {
	Sequence uint64   `json:"sequence"`
	Source   string   `json:"source,omitempty"`
	Cursor   Cursor   `json:"cursor"`
	Events   []Event  `json:"events,omitempty"`
	Exposed  []string `json:"exposed,omitempty"`
	Time     int64    `json:"time"`
}
type State struct {
	mu     sync.Mutex
	image  image
	dir    string
	wal    *os.File
	lock   *os.File
	budget int
	writes int
	failed error
}

func key(e Event) string { b, _ := json.Marshal(e.Labels); return e.Metric + string(b) }
func Open(dir string, budget int) (*State, error) {
	if budget < 1 || budget > 10000 {
		return nil, errors.New("detail budget must be between 1 and 10000")
	}
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	s := &State{dir: dir, budget: budget, image: image{Counters: map[string]Sample{}, Offsets: map[string]Cursor{}}}
	lock, err := os.OpenFile(filepath.Join(dir, "lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	s.lock = lock
	if err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		lock.Close()
		return nil, err
	}
	fail := func(e error) (*State, error) { s.Close(); return nil, e }
	b, err := os.ReadFile(filepath.Join(dir, "checkpoint.json"))
	if err == nil {
		if err = json.Unmarshal(b, &s.image); err != nil {
			return fail(err)
		}
	} else if !os.IsNotExist(err) {
		return fail(err)
	}
	if s.image.Counters == nil || s.image.Offsets == nil {
		return fail(errors.New("invalid checkpoint"))
	}
	s.wal, err = os.OpenFile(filepath.Join(dir, "journal.jsonl"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return fail(err)
	}
	directory, e := os.Open(dir)
	if e != nil {
		return fail(e)
	}
	e = directory.Sync()
	directory.Close()
	if e != nil {
		return fail(e)
	}
	parent, e := os.Open(filepath.Dir(dir))
	if e != nil {
		return fail(e)
	}
	e = parent.Sync()
	parent.Close()
	if e != nil {
		return fail(e)
	}
	reader := bufio.NewReader(s.wal)
	var complete int64
	for {
		line, e := reader.ReadBytes('\n')
		if e == io.EOF {
			if len(line) > 0 {
				if err = s.wal.Truncate(complete); err != nil {
					return fail(err)
				}
			}
			break
		}
		if e != nil {
			return fail(e)
		}
		var tx transaction
		if err = json.Unmarshal(line, &tx); err != nil {
			return fail(fmt.Errorf("invalid committed journal: %w", err))
		}
		if tx.Sequence > s.image.Sequence {
			if tx.Sequence != s.image.Sequence+1 {
				return fail(errors.New("journal sequence gap"))
			}
			s.apply(tx)
		}
		complete += int64(len(line))
	}
	_, err = s.wal.Seek(0, io.SeekEnd)
	if err != nil {
		return fail(err)
	}
	return s, nil
}
func (s *State) Close() error {
	if s.wal != nil {
		s.wal.Close()
	}
	if s.lock != nil {
		syscall.Flock(int(s.lock.Fd()), syscall.LOCK_UN)
		return s.lock.Close()
	}
	return nil
}
func (s *State) Position(source string) Cursor {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.image.Offsets[source]
}
func (s *State) Snapshot() []Sample {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]Sample, 0, len(s.image.Counters))
	for k, v := range s.image.Counters {
		v.Key = k
		if v.Fresh {
			v.Value = 0
		}
		out = append(out, v)
	}
	return out
}
func (s *State) DetailCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	n := 0
	for _, v := range s.image.Counters {
		if v.Metric == "familytraffic_access_events_total" {
			n++
		}
	}
	return n
}
func (s *State) Commit(source string, cursor Cursor, events []Event, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.append(transaction{Source: source, Cursor: cursor, Events: events, Time: now.Unix()})
}
func (s *State) Exposed(keys []string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	fresh := []string{}
	for _, k := range keys {
		if s.image.Counters[k].Fresh {
			fresh = append(fresh, k)
		}
	}
	if len(fresh) == 0 {
		return nil
	}
	return s.append(transaction{Exposed: fresh, Time: time.Now().Unix()})
}
func (s *State) append(tx transaction) (err error) {
	defer func() {
		if err != nil {
			s.failed = err
		}
	}()
	if s.failed != nil {
		return s.failed
	}
	tx.Sequence = s.image.Sequence + 1
	b, err := json.Marshal(tx)
	if err != nil {
		return err
	}
	b = append(b, '\n')
	if n, e := s.wal.Write(b); e != nil || n != len(b) {
		if e == nil {
			e = io.ErrShortWrite
		}
		s.failed = e
		return e
	}
	if err = s.wal.Sync(); err != nil {
		s.failed = err
		return err
	}
	s.apply(tx)
	s.writes++
	if s.writes >= 1000 {
		if err = s.checkpoint(); err != nil {
			return err
		}
		if err = s.wal.Truncate(0); err != nil {
			return err
		}
		if _, err = s.wal.Seek(0, io.SeekStart); err != nil {
			return err
		}
		s.writes = 0
	}
	return nil
}
func (s *State) apply(tx transaction) {
	// Admission and expiry are replayed at the committed transaction timestamp.
	count := 0
	for k, v := range s.image.Counters {
		if v.Metric == "familytraffic_access_events_total" {
			if tx.Time-v.LastSeen > 30*86400 {
				delete(s.image.Counters, k)
			} else {
				count++
			}
		}
	}
	for _, e := range tx.Events {
		k := key(e)
		v, ok := s.image.Counters[k]
		if e.Metric == "familytraffic_access_events_total" && !ok {
			if count >= s.budget {
				e = ev("detail_overflow_total", map[string]string{"family": "access"}, 1)
				k = key(e)
				v, ok = s.image.Counters[k]
			} else {
				count++
			}
		}
		if !ok {
			v = Sample{Event: Event{Metric: e.Metric, Labels: e.Labels}, Fresh: true}
		}
		v.Value += e.Value
		v.LastSeen = tx.Time
		s.image.Counters[k] = v
	}
	for _, k := range tx.Exposed {
		v, ok := s.image.Counters[k]
		if ok {
			v.Fresh = false
			s.image.Counters[k] = v
		}
	}
	if tx.Source != "" {
		s.image.Offsets[tx.Source] = tx.Cursor
	}
	s.image.Sequence = tx.Sequence
}
func (s *State) checkpoint() error {
	b, err := json.Marshal(s.image)
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(s.dir, "checkpoint-*")
	if err != nil {
		return err
	}
	name := f.Name()
	defer os.Remove(name)
	if err = f.Chmod(0600); err == nil {
		_, err = f.Write(b)
	}
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	if err = os.Rename(name, filepath.Join(s.dir, "checkpoint.json")); err != nil {
		return err
	}
	d, err := os.Open(s.dir)
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}
func (s *State) Failure() error { s.mu.Lock(); defer s.mu.Unlock(); return s.failed }

// Expire releases inactive address labels after their promised retention window.
func (s *State) Expire(now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, v := range s.image.Counters {
		if v.Metric == "familytraffic_access_events_total" && now.Unix()-v.LastSeen > 30*86400 {
			return s.append(transaction{Time: now.Unix()})
		}
	}
	return nil
}
