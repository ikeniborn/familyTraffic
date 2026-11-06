package journal

import (
	"encoding/json"
	"errors"
	"net"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
)

type Event struct {
	Metric string            `json:"metric"`
	Labels map[string]string `json:"labels"`
	Value  float64           `json:"value"`
}

var access = regexp.MustCompile(`(?:from )?(\S+) (accepted|rejected) (\S+)(?:.*?\[([^\] ]+) (?:->|>>) [^\]]+\])?(?:.*?email: (\S+))?`)
var ban = regexp.MustCompile(`\[(sshd|familytraffic-proxy-auth)\].*?\b(Restore Ban|Ban|Unban) ([0-9a-fA-F:.]+)`)
var protocol = regexp.MustCompile(`\bprotocol=(http|socks)\b`)
var token = regexp.MustCompile(`^[a-zA-Z0-9_.@-]{1,128}$`)

func ev(name string, labels map[string]string, value float64) Event {
	return Event{Metric: "familytraffic_" + name, Labels: labels, Value: value}
}
func host(value string) (string, error) {
	for _, prefix := range []string{"tcp:", "udp:"} {
		value = strings.TrimPrefix(value, prefix)
	}
	if strings.Contains(value, "://") {
		u, err := url.Parse(value)
		if err != nil || u.Hostname() == "" {
			return "", errors.New("invalid destination")
		}
		value = u.Host
	}
	if h, p, err := net.SplitHostPort(value); err == nil {
		if p != "" {
			value = net.JoinHostPort(strings.ToLower(h), p)
		}
	} else {
		value = strings.ToLower(value)
	}
	// URL parsing removes credentials and all request metadata.
	if strings.Contains(value, "@") || strings.ContainsAny(value, "/?#\"\\ \t\r\n") || len(value) > 300 || value == "" {
		return "", errors.New("invalid host")
	}
	return value, nil
}
func clientIP(value string) string {
	value = strings.TrimPrefix(strings.TrimPrefix(value, "tcp:"), "udp:")
	if h, _, err := net.SplitHostPort(value); err == nil {
		value = h
	}
	if ip := net.ParseIP(value); ip != nil && !ip.IsLoopback() {
		return ip.String()
	}
	return "unknown"
}
func Parse(source, line string, now time.Time) ([]Event, error) {
	_ = now
	if len(line) > 16384 {
		return nil, errors.New("oversized record")
	}
	switch source {
	case "access":
		m := access.FindStringSubmatch(line)
		if m == nil {
			return nil, errors.New("invalid access record")
		}
		inbound := m[4]
		if !token.MatchString(inbound) {
			inbound = "unknown"
		}
		out := []Event{ev("access_total", map[string]string{"inbound": inbound, "status": m[2]}, 1)}
		if m[2] != "accepted" {
			return out, nil
		}
		destination, err := host(m[3])
		if err != nil {
			return out, err
		}
		user := m[5]
		if !token.MatchString(user) {
			user = "unknown"
		}
		return append(out, ev("access_events_total", map[string]string{"user_id": user, "client_ip": clientIP(m[1]), "destination": destination, "inbound": inbound}, 1)), nil
	case "nginx":
		var n struct {
			Listener string  `json:"listener"`
			Status   string  `json:"status"`
			Received float64 `json:"received"`
			Sent     float64 `json:"sent"`
		}
		if err := json.Unmarshal([]byte(line), &n); err != nil {
			return nil, err
		}
		if n.Received < 0 || n.Sent < 0 {
			return nil, errors.New("negative bytes")
		}
		labels := map[string]string{"443": "vless-front", "1080": "socks5s", "8118": "https", "1081": "socks5", "8119": "http"}
		listener, ok := labels[n.Listener]
		if !ok {
			return nil, nil
		}
		status := "error"
		if n.Status == "200" {
			status = "success"
		}
		return []Event{ev("frontend_bytes_total", map[string]string{"listener": listener, "direction": "upload"}, n.Received), ev("frontend_bytes_total", map[string]string{"listener": listener, "direction": "download"}, n.Sent), ev("frontend_sessions_total", map[string]string{"listener": listener, "status": status}, 1)}, nil
	case "auth":
		if !strings.Contains(line, "FT_AUTH_FAILURE") {
			return nil, nil
		}
		m := protocol.FindStringSubmatch(line)
		if m == nil {
			return nil, errors.New("invalid auth record")
		}
		return []Event{ev("auth_failures_total", map[string]string{"protocol": m[1]}, 1)}, nil
	case "fail2ban":
		m := ban.FindStringSubmatch(line)
		if m == nil {
			return nil, nil
		}
		if net.ParseIP(m[3]) == nil {
			return nil, errors.New("invalid ban IP")
		}
		action := map[string]string{"Ban": "ban", "Unban": "unban", "Restore Ban": "restore"}[m[2]]
		return []Event{ev("fail2ban_events_total", map[string]string{"jail": m[1], "action": action}, 1)}, nil
	case "error":
		if !strings.Contains(line, "Warning") && !strings.Contains(line, "Error") && !strings.Contains(line, "WARNING") && !strings.Contains(line, "ERROR") {
			return nil, nil
		}
		lower := strings.ToLower(line)
		reason := "unknown"
		for _, r := range []struct{ word, reason string }{{"timeout", "timeout"}, {"refused", "refused"}, {"dns", "dns"}, {"tls", "tls"}, {"auth", "authentication"}, {"reject", "routing"}} {
			if strings.Contains(lower, r.word) {
				reason = r.reason
				break
			}
		}
		return []Event{ev("errors_total", map[string]string{"source": "xray", "reason": reason}, 1)}, nil
	}
	return nil, errors.New("unknown source " + strconv.Quote(source))
}
