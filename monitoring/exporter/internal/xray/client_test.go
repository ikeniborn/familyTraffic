package xray

import (
	"context"
	"github.com/xtls/xray-core/app/stats/command"
	"google.golang.org/grpc"
	"testing"
)

type fake struct {
	reset  bool
	values []*command.Stat
}

func (f *fake) QueryStats(_ context.Context, r *command.QueryStatsRequest, _ ...grpc.CallOption) (*command.QueryStatsResponse, error) {
	f.reset = r.Reset_
	return &command.QueryStatsResponse{Stat: f.values}, nil
}
func TestNativeCountersAndSharedIdentity(t *testing.T) {
	f := &fake{values: []*command.Stat{{Name: "user>>>alice>>>traffic>>>uplink", Value: 123}, {Name: "inbound>>>http-proxy>>>traffic>>>downlink", Value: 45}, {Name: "bad", Value: 1}}}
	c := Client{RPC: f}
	values, bad, err := c.Read(context.Background(), map[string]Identity{"alice": {UserID: "alice", AccountClass: "proxy"}})
	if err != nil || f.reset || bad != 1 || len(values) != 2 {
		t.Fatalf("values=%v bad=%d err=%v reset=%v", values, bad, err, f.reset)
	}
	if values[0].Value != 123 || values[0].Labels["account_class"] != "proxy" {
		t.Fatal(values)
	}
	f.values[0].Value = 2
	values, _, _ = c.Read(context.Background(), map[string]Identity{})
	if values[0].Value != 2 || values[0].Labels["user_id"] != "unknown" {
		t.Fatal(values)
	}
}
