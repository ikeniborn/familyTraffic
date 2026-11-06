package journal

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

type Tailer struct {
	State      *State
	StartAtEnd bool
}

func fileID(info os.FileInfo) string {
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return ""
	}
	return fmt.Sprintf("%d:%d", st.Dev, st.Ino)
}
func (t Tailer) Poll(source, path string, users map[string]string, now time.Time) error {
	if marker, e := os.ReadFile(filepath.Join(filepath.Dir(path), "traffic-rotation-generation")); e == nil {
		generation := strings.TrimSpace(string(marker))
		if len(generation) > 64 {
			return errors.New("invalid rotation generation")
		}
		previous := t.State.Position("rotation:" + source)
		if previous.ID != generation {
			events := []Event{}
			if previous.ID != "" || t.State.Position(source).ID != "" {
				events = append(events, ev("collection_gaps_total", map[string]string{"source": source, "reason": "copytruncate_possible_loss"}, 1))
			}
			if e = t.State.Commit("rotation:"+source, Cursor{ID: generation}, events, now); e != nil {
				return e
			}
		}
	}
	current, err := os.Stat(path)
	if err != nil {
		return err
	}
	id := fileID(current)
	cursor := t.State.Position(source)
	if cursor.ID == "" && t.StartAtEnd {
		return t.State.Commit(source, Cursor{ID: id, Offset: current.Size()}, nil, now)
	}
	events := []Event{}
	if cursor.ID != "" && cursor.ID != id {
		found := false
		entries, e := os.ReadDir(filepath.Dir(path))
		if e != nil {
			return e
		}
		for _, entry := range entries {
			info, e := entry.Info()
			if e == nil && info.Mode().IsRegular() && fileID(info) == cursor.ID {
				found = true
				done, e := t.read(source, filepath.Join(filepath.Dir(path), entry.Name()), cursor, users, now)
				if e != nil {
					return e
				}
				if !done {
					position := t.State.Position(source)
					remaining := info.Size() - position.Offset
					if remaining > 0 && remaining <= 16384 {
						if e = t.State.Commit(source, Cursor{ID: cursor.ID, Offset: info.Size()}, []Event{ev("collection_gaps_total", map[string]string{"source": source, "reason": "rotated_partial_record"}, 1)}, now); e != nil {
							return e
						}
					} else {
						return nil
					}
				}
				break
			}
		}
		if !found {
			events = append(events, ev("collection_gaps_total", map[string]string{"source": source, "reason": "rotation_loss"}, 1))
		}
		cursor = Cursor{ID: id}
		if err = t.State.Commit(source, cursor, events, now); err != nil {
			return err
		}
	}
	if cursor.ID == "" {
		cursor.ID = id
	}
	if current.Size() < cursor.Offset {
		cursor.Offset = 0
		events = []Event{ev("collection_gaps_total", map[string]string{"source": source, "reason": "truncated"}, 1)}
		if err = t.State.Commit(source, cursor, events, now); err != nil {
			return err
		}
	}
	_, err = t.read(source, path, cursor, users, now)
	return err
}
func (t Tailer) read(source, path string, cursor Cursor, users map[string]string, now time.Time) (bool, error) {
	f, err := os.Open(path)
	if err != nil {
		return false, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return false, err
	}
	if fileID(info) != cursor.ID {
		return false, errors.New("file rotated during read")
	}
	if _, err = f.Seek(cursor.Offset, io.SeekStart); err != nil {
		return false, err
	}
	reader := bufio.NewReaderSize(f, 16384)
	events := []Event{}
	consumed := int64(0)
	committed := cursor.Offset
	for consumed < 8*1024*1024 {
		line, e := reader.ReadSlice('\n')
		size := int64(len(line))
		oversized := e == bufio.ErrBufferFull
		if oversized {
			for e == bufio.ErrBufferFull {
				chunk, next := reader.ReadSlice('\n')
				size += int64(len(chunk))
				e = next
			}
			line = nil
		}
		if e == io.EOF {
			break
		}
		if e != nil {
			return false, e
		}
		consumed += size
		committed += size
		parsed, parseErr := Parse(source, string(line), now)
		if oversized {
			parseErr = errors.New("oversized record")
		}
		if parseErr != nil {
			events = append(events, ev("parse_errors_total", map[string]string{"source": source}, 1))
		}
		for _, event := range parsed {
			if event.Metric == "familytraffic_access_events_total" {
				raw := event.Labels["user_id"]
				user, ok := users[raw]
				if !ok {
					user = "unknown"
				}
				event.Labels["user_id"] = user
			}
			events = append(events, event)
		}
		if len(events) >= 256 {
			if err = t.State.Commit(source, Cursor{ID: cursor.ID, Offset: committed}, events, now); err != nil {
				return false, err
			}
			events = nil
		}
	}
	if committed != cursor.Offset {
		if err = t.State.Commit(source, Cursor{ID: cursor.ID, Offset: committed}, events, now); err != nil {
			return false, err
		}
	}
	info, err = f.Stat()
	if err != nil {
		return false, err
	}
	return committed >= info.Size(), nil
}
