package fail2ban

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestSnapshotFreshnessAndLimit(t *testing.T) {
	p := filepath.Join(t.TempDir(), "status.json")
	os.WriteFile(p, []byte(`{"timestamp":100,"jails":{"sshd":{"count":2,"ips":["192.0.2.1","bad"]}}}`), 0600)
	if _, err := Read(p, time.Unix(120, 0)); err == nil {
		t.Fatal("bad IP accepted")
	}
	os.WriteFile(p, []byte(`{"timestamp":100,"jails":{"sshd":{"count":1,"ips":["192.0.2.1"]}}}`), 0600)
	if _, err := Read(p, time.Unix(120, 0)); err != nil {
		t.Fatal(err)
	}
	if _, err := Read(p, time.Unix(161, 0)); err == nil {
		t.Fatal("stale accepted")
	}
}
