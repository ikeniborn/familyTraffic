package collector

import (
	"github.com/ikeniborn/familyTraffic/monitoring/exporter/internal/journal"
	"github.com/ikeniborn/familyTraffic/monitoring/exporter/internal/xray"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/testutil"
	"strings"
	"testing"
	"time"
)

func TestFailedSourceOmitsNativeAndUnknownSamplesAggregate(t *testing.T) {
	c := New(nil)
	c.UpdateNative([]xray.Counter{{Metric: "familytraffic_user_bytes_total", Labels: map[string]string{"user_id": "unknown", "direction": "upload", "account_class": "unknown"}, Value: 2}, {Metric: "familytraffic_user_bytes_total", Labels: map[string]string{"user_id": "unknown", "direction": "upload", "account_class": "unknown"}, Value: 3}}, true, 100)
	r := prometheus.NewRegistry()
	r.MustRegister(c)
	m, err := r.Gather()
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, v := range m {
		if v.GetName() == "familytraffic_user_bytes_total" {
			found = true
			if len(v.Metric) != 1 || v.Metric[0].Counter.GetValue() != 5 {
				t.Fatal(v)
			}
		}
	}
	if !found {
		t.Fatal("missing counter")
	}
	c.UpdateNative(nil, false, 101)
	text := testutil.CollectAndCount(c, "familytraffic_user_bytes_total")
	if text != 0 {
		t.Fatal(text)
	}
	if err := testutil.CollectAndCompare(c, strings.NewReader("# HELP familytraffic_source_up Whether a collection source is available.\n# TYPE familytraffic_source_up gauge\nfamilytraffic_source_up{source=\"xray\"} 0\n"), "familytraffic_source_up"); err != nil {
		t.Fatal(err)
	}
}
func TestLegacyPersistedAPIAccessIsNeverExposed(t *testing.T) {
	state, err := journal.Open(t.TempDir(), 10)
	if err != nil {
		t.Fatal(err)
	}
	defer state.Close()
	state.Commit("access", journal.Cursor{ID: "file", Offset: 1}, []journal.Event{{Metric: "familytraffic_access_total", Labels: map[string]string{"inbound": "traffic-api", "status": "accepted"}, Value: 1}, {Metric: "familytraffic_access_events_total", Labels: map[string]string{"inbound": "traffic-api", "user_id": "unknown", "client_ip": "unknown", "destination": "127.0.0.1:0"}, Value: 1}}, time.Now())
	c := New(state)
	c.Health("access", true, 100)
	if n := testutil.CollectAndCount(c, "familytraffic_access_total", "familytraffic_access_events_total"); n != 0 {
		t.Fatalf("legacy administrative rows exposed: %d", n)
	}
}
