package journal

import (
	"strings"
	"testing"
	"time"
)

func TestAccessSanitizesAndPreservesAttribution(t *testing.T) {
	events, err := Parse("access", "2026/11/06 12:00:00.123 from tcp:192.0.2.1:1234 accepted https://name:secret@example.org/private?q=secret [http-proxy -> direct] email: alice", time.Now())
	if err != nil || len(events) != 2 {
		t.Fatalf("%v %v", events, err)
	}
	for _, e := range events {
		for _, v := range e.Labels {
			if strings.Contains(v, "secret") || strings.Contains(v, "private") {
				t.Fatal(e)
			}
		}
	}
	if events[1].Labels["user_id"] != "alice" || events[1].Labels["inbound"] != "http-proxy" {
		t.Fatal(events)
	}
	if events[1].Labels["destination"] != "example.org" || events[1].Labels["client_ip"] != "192.0.2.1" {
		t.Fatal(events)
	}
}
func TestIPv6AndUnknown(t *testing.T) {
	e, err := Parse("access", "2026/11/06 from [2001:db8::1]:345 accepted tcp:[2001:db8::2]:443 [vless-reality -> direct]", time.Now())
	if err != nil || len(e) != 2 || e[1].Labels["client_ip"] != "2001:db8::1" || e[1].Labels["user_id"] != "unknown" {
		t.Fatalf("%v %v", e, err)
	}
}
func TestFrontendAndBans(t *testing.T) {
	e, err := Parse("nginx", `{"time":"2026-11-06T12:00:00Z","listener":"8118","client_ip":"192.0.2.1","status":"200","duration":1,"received":123,"sent":456}`, time.Now())
	if err != nil || len(e) != 3 || e[0].Value != 123 {
		t.Fatalf("%v %v", e, err)
	}
	e, err = Parse("fail2ban", "2026-11-06 [familytraffic-proxy-auth] Restore Ban 192.0.2.1", time.Now())
	if err != nil || e[0].Labels["action"] != "restore" {
		t.Fatalf("%v %v", e, err)
	}
}
func TestConnectAuthorityURLPreservesDestination(t *testing.T) {
	events, err := Parse("access", "2026/11/06 12:00:00.123 from tcp:192.0.2.1:1234 accepted //target.lab:443 [http-proxy -> direct] email: fixture-user", time.Now())
	if err != nil || len(events) != 2 || events[1].Labels["destination"] != "target.lab:443" {
		t.Fatalf("events=%v error=%v", events, err)
	}
}
func TestStatsAPIRequestsAreNotUserAccess(t *testing.T) {
	events, err := Parse("access", "2026/11/06 05:48:37 from 127.0.0.1:54800 accepted tcp:127.0.0.1:0 [traffic-api -> traffic-api]", time.Now())
	if err != nil || len(events) != 0 {
		t.Fatalf("admin API counted as user access: %v %v", events, err)
	}
}
