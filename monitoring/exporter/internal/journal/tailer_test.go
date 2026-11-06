package journal

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestRotationDrainsOldAndDoesNotReplay(t *testing.T) {
	d := t.TempDir()
	p := filepath.Join(d, "auth.log")
	s, _ := Open(filepath.Join(d, "state"), 10)
	defer s.Close()
	tail := Tailer{State: s}
	os.WriteFile(p, []byte("FT_AUTH_FAILURE protocol=http src=192.0.2.1\n"), 0600)
	if err := tail.Poll("auth", p, nil, time.Now()); err != nil {
		t.Fatal(err)
	}
	os.Rename(p, p+".1")
	os.WriteFile(p, []byte("FT_AUTH_FAILURE protocol=http src=192.0.2.2\n"), 0600)
	if err := tail.Poll("auth", p, nil, time.Now()); err != nil {
		t.Fatal(err)
	}
	tail.Poll("auth", p, nil, time.Now())
	a := s.Snapshot()
	keys := []string{}
	for _, v := range a {
		keys = append(keys, v.Key)
	}
	s.Exposed(keys)
	for _, v := range s.Snapshot() {
		if v.Metric == "familytraffic_auth_failures_total" && v.Value != 2 {
			t.Fatal(v)
		}
	}
}
func TestRotatedPartialRecordDoesNotStallNewFile(t *testing.T) {
	d := t.TempDir()
	p := filepath.Join(d, "auth.log")
	s, _ := Open(filepath.Join(d, "state"), 10)
	defer s.Close()
	tail := Tailer{State: s}
	os.WriteFile(p, []byte("FT_AUTH_FAILURE protocol=http src=192.0.2.1\npartial"), 0600)
	tail.Poll("auth", p, nil, time.Now())
	os.Rename(p, p+".1")
	os.WriteFile(p, []byte("FT_AUTH_FAILURE protocol=socks src=192.0.2.1\n"), 0600)
	if err := tail.Poll("auth", p, nil, time.Now()); err != nil {
		t.Fatal(err)
	}
	if s.Position("auth").ID == "" || s.Position("auth").Offset != 46 { // Compare directly with actual file size below.
		st, _ := os.Stat(p)
		if s.Position("auth").Offset != st.Size() {
			t.Fatal(s.Position("auth"), st.Size())
		}
	}
	found := false
	for _, v := range s.Snapshot() {
		if v.Metric == "familytraffic_collection_gaps_total" {
			found = true
		}
	}
	if !found {
		t.Fatal("missing partial record gap")
	}
}
func TestCopytruncateRegrowMarkedIncomplete(t *testing.T) {
	d := t.TempDir()
	p := filepath.Join(d, "auth.log")
	marker := filepath.Join(d, "traffic-rotation-generation")
	s, _ := Open(filepath.Join(d, "state"), 10)
	defer s.Close()
	tail := Tailer{State: s}
	line := "FT_AUTH_FAILURE protocol=http src=192.0.2.1\n"
	os.WriteFile(p, []byte(line), 0600)
	os.WriteFile(marker, []byte("one"), 0600)
	tail.Poll("auth", p, nil, time.Now())
	os.WriteFile(p, []byte(line+line+line), 0600)
	os.WriteFile(marker, []byte("two"), 0600)
	tail.Poll("auth", p, nil, time.Now())
	found := false
	for _, v := range s.Snapshot() {
		if v.Metric == "familytraffic_collection_gaps_total" && v.Labels["reason"] == "copytruncate_possible_loss" {
			found = true
		}
	}
	if !found {
		t.Fatal("truncate-regrow must not look complete")
	}
}
func TestFirstCopytruncateMarkerMarksPossibleLoss(t *testing.T) {
	d := t.TempDir()
	p := filepath.Join(d, "auth.log")
	s, _ := Open(filepath.Join(d, "state"), 10)
	defer s.Close()
	tail := Tailer{State: s}
	line := "FT_AUTH_FAILURE protocol=http src=192.0.2.1\n"
	os.WriteFile(p, []byte(line), 0600)
	tail.Poll("auth", p, nil, time.Now())
	os.WriteFile(p, []byte(line+line+line), 0600)
	os.WriteFile(filepath.Join(d, "traffic-rotation-generation"), []byte("first"), 0600)
	tail.Poll("auth", p, nil, time.Now())
	for _, v := range s.Snapshot() {
		if v.Metric == "familytraffic_collection_gaps_total" && v.Labels["reason"] == "copytruncate_possible_loss" {
			return
		}
	}
	t.Fatal("first copytruncate marker skipped")
}
