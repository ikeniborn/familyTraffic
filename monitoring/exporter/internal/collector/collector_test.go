package collector

import (
	"github.com/ikeniborn/familyTraffic/monitoring/exporter/internal/xray"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/testutil"
	"strings"
	"testing"
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
