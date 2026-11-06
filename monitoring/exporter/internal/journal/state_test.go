package journal

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestCommitReplayAndBaseline(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(dir, 2)
	if err != nil {
		t.Fatal(err)
	}
	e := ev("access_events_total", map[string]string{"user_id": "alice", "destination": "example.org", "client_ip": "192.0.2.1", "inbound": "http"}, 1)
	if err = s.Commit("access", Cursor{ID: "1", Offset: 123}, []Event{e}, time.Now()); err != nil {
		t.Fatal(err)
	}
	snap := s.Snapshot()
	if len(snap) != 1 || snap[0].Value != 0 {
		t.Fatal(snap)
	}
	s.Exposed([]string{snap[0].Key})
	if s.Snapshot()[0].Value != 1 {
		t.Fatal(s.Snapshot())
	}
	s.Close()
	s, err = Open(dir, 2)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if s.Position("access").Offset != 123 || s.Snapshot()[0].Value != 1 {
		t.Fatal("lost transaction")
	}
}
func TestPartialTailAndAdmissionCap(t *testing.T) {
	dir := t.TempDir()
	s, _ := Open(dir, 1)
	s.Commit("access", Cursor{ID: "1", Offset: 1}, []Event{ev("access_events_total", map[string]string{"destination": "a"}, 1)}, time.Now())
	s.Commit("access", Cursor{ID: "1", Offset: 2}, []Event{ev("access_events_total", map[string]string{"destination": "b"}, 1), ev("access_total", map[string]string{"inbound": "http", "status": "accepted"}, 1)}, time.Now())
	s.Close()
	f, _ := os.OpenFile(filepath.Join(dir, "journal.jsonl"), os.O_APPEND|os.O_WRONLY, 0600)
	f.WriteString(`{"partial"`)
	f.Close()
	s, err := Open(dir, 1)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	foundOverflow, foundSummary := false, false
	for _, v := range s.Snapshot() {
		if v.Metric == "familytraffic_detail_overflow_total" {
			foundOverflow = true
		}
		if v.Metric == "familytraffic_access_total" {
			foundSummary = true
		}
	}
	if !foundOverflow || !foundSummary {
		t.Fatal(s.Snapshot())
	}
}
func TestSnapshotAndJournalOverlap(t *testing.T) {
	dir := t.TempDir()
	s, _ := Open(dir, 1)
	s.Commit("auth", Cursor{ID: "1", Offset: 1}, []Event{ev("auth_failures_total", map[string]string{"protocol": "http"}, 3)}, time.Now())
	// Simulate crash after checkpoint rename but before WAL truncation.
	if err := s.checkpoint(); err != nil {
		t.Fatal(err)
	}
	s.Close()
	s, err := Open(dir, 1)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	v := s.Snapshot()
	s.Exposed([]string{v[0].Key})
	if s.Snapshot()[0].Value != 3 {
		t.Fatal("duplicated checkpoint record")
	}
}
func TestIdleDetailExpiresWithoutNewEvents(t *testing.T) {
	s, _ := Open(t.TempDir(), 1)
	defer s.Close()
	then := time.Unix(1000, 0)
	s.Commit("access", Cursor{ID: "1", Offset: 1}, []Event{ev("access_events_total", map[string]string{"destination": "a"}, 1)}, then)
	if s.DetailCount() != 1 {
		t.Fatal("not admitted")
	}
	if err := s.Expire(then.Add(31 * 24 * time.Hour)); err != nil {
		t.Fatal(err)
	}
	if s.DetailCount() != 0 {
		t.Fatal("idle series not expired")
	}
}
