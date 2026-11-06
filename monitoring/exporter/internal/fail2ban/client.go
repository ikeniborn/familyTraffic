package fail2ban

import (
	"encoding/json"
	"errors"
	"net"
	"os"
	"time"
)

type Jail struct {
	Count    int      `json:"count"`
	IPs      []string `json:"ips"`
	Overflow int      `json:"overflow"`
}
type Snapshot struct {
	Timestamp float64            `json:"timestamp"`
	Jails     map[string]Jail    `json:"jails"`
	Auth      map[string]float64 `json:"auth"`
	AuthUp    bool               `json:"auth_up"`
	AuthGaps  float64            `json:"auth_gaps"`
}

func Read(path string, now time.Time) (Snapshot, error) {
	var s Snapshot
	b, err := os.ReadFile(path)
	if err != nil {
		return s, err
	}
	if len(b) > 1024*1024 {
		return s, errors.New("oversized snapshot")
	}
	if err = json.Unmarshal(b, &s); err != nil {
		return s, err
	}
	age := float64(now.Unix()) - s.Timestamp
	if age < -5 || age > 60 {
		return s, errors.New("stale snapshot")
	}
	for name, j := range s.Jails {
		if name != "sshd" && name != "familytraffic-proxy-auth" {
			return s, errors.New("unexpected jail")
		}
		if j.Count < 0 || j.Overflow < 0 || len(j.IPs) > 1000 {
			return s, errors.New("invalid jail counts")
		}
		for _, ip := range j.IPs {
			if net.ParseIP(ip) == nil {
				return s, errors.New("invalid IP")
			}
		}
	}
	if len(s.Jails) == 0 {
		return s, errors.New("empty snapshot")
	}
	return s, nil
}
