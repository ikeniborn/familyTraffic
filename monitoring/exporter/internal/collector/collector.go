package collector

import (
	"encoding/json"
	"github.com/ikeniborn/familyTraffic/monitoring/exporter/internal/fail2ban"
	"github.com/ikeniborn/familyTraffic/monitoring/exporter/internal/journal"
	"github.com/ikeniborn/familyTraffic/monitoring/exporter/internal/xray"
	"github.com/prometheus/client_golang/prometheus"
	"sort"
	"sync"
)

type Health struct {
	Up   bool
	Last float64
}
type Collector struct {
	mu     sync.RWMutex
	State  *journal.State
	native []xray.Counter
	health map[string]Health
	bans   fail2ban.Snapshot
}

func New(state *journal.State) *Collector {
	return &Collector{State: state, health: map[string]Health{}}
}
func (c *Collector) Health(source string, up bool, now float64) {
	c.mu.Lock()
	defer c.mu.Unlock()
	h := c.health[source]
	h.Up = up
	if up {
		h.Last = now
	}
	c.health[source] = h
}
func (c *Collector) UpdateNative(values []xray.Counter, up bool, now float64) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.native = values
	h := c.health["xray"]
	h.Up = up
	if up {
		h.Last = now
	}
	c.health["xray"] = h
}
func (c *Collector) UpdateBans(v fail2ban.Snapshot, up bool, now float64) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.bans = v
	ah := c.health["auth"]
	ah.Up = up && v.AuthUp
	if ah.Up {
		ah.Last = now
	}
	c.health["auth"] = ah
	h := c.health["fail2ban_state"]
	h.Up = up
	if up {
		h.Last = now
	}
	c.health["fail2ban_state"] = h
}
func (c *Collector) Describe(ch chan<- *prometheus.Desc) { prometheus.DescribeByCollect(c, ch) }
func emit(ch chan<- prometheus.Metric, name, help string, labels map[string]string, value float64, kind prometheus.ValueType) {
	names := make([]string, 0, len(labels))
	for k := range labels {
		names = append(names, k)
	}
	sort.Strings(names)
	values := []string{}
	for _, k := range names {
		values = append(values, labels[k])
	}
	ch <- prometheus.MustNewConstMetric(prometheus.NewDesc(name, help, names, nil), kind, value, values...)
}
func sourceOf(metric string) string {
	switch metric {
	case "familytraffic_access_total", "familytraffic_access_events_total":
		return "access"
	case "familytraffic_frontend_bytes_total", "familytraffic_frontend_sessions_total":
		return "nginx"
	case "familytraffic_auth_failures_total":
		return "auth"
	case "familytraffic_fail2ban_events_total":
		return "fail2ban"
	case "familytraffic_errors_total":
		return "error"
	}
	return ""
}
func (c *Collector) Collect(ch chan<- prometheus.Metric) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	for source, h := range c.health {
		up := 0.0
		if h.Up {
			up = 1
		}
		emit(ch, "familytraffic_source_up", "Whether a collection source is available.", map[string]string{"source": source}, up, prometheus.GaugeValue)
		emit(ch, "familytraffic_last_success_timestamp_seconds", "Unix time of last successful source collection.", map[string]string{"source": source}, h.Last, prometheus.GaugeValue)
	}
	if c.health["xray"].Up {
		type item struct{ v xray.Counter }
		all := map[string]item{}
		for _, v := range c.native {
			b, _ := json.Marshal(v.Labels)
			k := v.Metric + string(b)
			if existing, ok := all[k]; ok {
				v.Value += existing.v.Value
			}
			all[k] = item{v: v}
		}
		for _, x := range all {
			emit(ch, x.v.Metric, "Native Xray traffic bytes at the documented counter boundary.", x.v.Labels, x.v.Value, prometheus.CounterValue)
		}
	}
	if c.State != nil {
		for _, v := range c.State.Snapshot() {
			source := sourceOf(v.Metric)
			if source != "" && !c.health[source].Up {
				continue
			}
			emit(ch, v.Metric, "Durable log-derived traffic monitoring counter.", v.Labels, v.Value, prometheus.CounterValue)
		}
		emit(ch, "familytraffic_detail_series", "Currently admitted address detail series.", map[string]string{"family": "access"}, float64(c.State.DetailCount()), prometheus.GaugeValue)
	}
	if c.health["fail2ban_state"].Up {
		left := 1000
		names := []string{}
		for name := range c.bans.Jails {
			names = append(names, name)
		}
		sort.Strings(names)
		for _, name := range names {
			j := c.bans.Jails[name]
			emit(ch, "familytraffic_fail2ban_banned", "Current banned IP count.", map[string]string{"jail": name}, float64(j.Count), prometheus.GaugeValue)
			overflow := j.Overflow
			for _, ip := range j.IPs {
				if left == 0 {
					overflow++
					continue
				}
				left--
				emit(ch, "familytraffic_fail2ban_ip_banned", "Currently banned IP, not a banned user.", map[string]string{"jail": name, "client_ip": ip}, 1, prometheus.GaugeValue)
			}
			emit(ch, "familytraffic_fail2ban_ip_overflow", "Current ban IP detail omitted by budget.", map[string]string{"jail": name}, float64(overflow), prometheus.GaugeValue)
		}
	}
}

// InitializationKeys returns only derived counters currently waiting for their first zero exposition.
func (c *Collector) InitializationKeys() []string {
	c.mu.RLock()
	defer c.mu.RUnlock()
	if c.State == nil {
		return nil
	}
	keys := []string{}
	for _, v := range c.State.Snapshot() {
		if v.Fresh {
			source := sourceOf(v.Metric)
			if source == "" || c.health[source].Up {
				keys = append(keys, v.Key)
			}
		}
	}
	return keys
}
