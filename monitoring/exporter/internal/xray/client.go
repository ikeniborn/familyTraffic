package xray

import (
	"context"
	"github.com/xtls/xray-core/app/stats/command"
	"google.golang.org/grpc"
	"strings"
)

type RPC interface {
	QueryStats(context.Context, *command.QueryStatsRequest, ...grpc.CallOption) (*command.QueryStatsResponse, error)
}
type Client struct{ RPC RPC }
type Identity struct {
	UserID       string `json:"user_id"`
	AccountClass string `json:"account_class"`
}
type Counter struct {
	Metric string
	Labels map[string]string
	Value  float64
}

func (c Client) Read(ctx context.Context, identities map[string]Identity) ([]Counter, int, error) {
	response, err := c.RPC.QueryStats(ctx, &command.QueryStatsRequest{Pattern: "", Reset_: false})
	if err != nil {
		return nil, 0, err
	}
	values := []Counter{}
	bad := 0
	for _, stat := range response.Stat {
		parts := strings.Split(stat.Name, ">>>")
		if len(parts) != 4 || parts[2] != "traffic" || stat.Value < 0 {
			bad++
			continue
		}
		direction := map[string]string{"uplink": "upload", "downlink": "download"}[parts[3]]
		if direction == "" {
			bad++
			continue
		}
		v := Counter{Value: float64(stat.Value), Labels: map[string]string{"direction": direction}}
		switch parts[0] {
		case "user":
			identity, ok := identities[parts[1]]
			if !ok {
				identity = Identity{UserID: "unknown", AccountClass: "unknown"}
			}
			v.Metric = "familytraffic_user_bytes_total"
			v.Labels["user_id"] = identity.UserID
			v.Labels["account_class"] = identity.AccountClass
		case "inbound", "outbound":
			if parts[1] == "traffic-api" {
				continue
			}
			v.Metric = "familytraffic_" + parts[0] + "_bytes_total"
			v.Labels[parts[0]] = parts[1]
		default:
			bad++
			continue
		}
		values = append(values, v)
	}
	return values, bad, nil
}
