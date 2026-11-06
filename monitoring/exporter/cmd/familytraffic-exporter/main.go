package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"github.com/ikeniborn/familyTraffic/monitoring/exporter/internal/collector"
	"github.com/ikeniborn/familyTraffic/monitoring/exporter/internal/fail2ban"
	"github.com/ikeniborn/familyTraffic/monitoring/exporter/internal/journal"
	"github.com/ikeniborn/familyTraffic/monitoring/exporter/internal/xray"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/xtls/xray-core/app/stats/command"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

type config struct {
	Listen       string            `json:"listen"`
	API          string            `json:"api"`
	Identity     string            `json:"identity"`
	StateDir     string            `json:"state_dir"`
	Fail2ban     string            `json:"fail2ban"`
	Logs         map[string]string `json:"logs"`
	DetailBudget int               `json:"detail_budget"`
}
type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(code int) { w.status = code; w.ResponseWriter.WriteHeader(code) }
func load(path string) (config, error) {
	var c config
	b, err := os.ReadFile(path)
	if err != nil {
		return c, err
	}
	err = json.Unmarshal(b, &c)
	if c.Listen == "" || c.API == "" || c.Identity == "" || c.StateDir == "" {
		return c, fmt.Errorf("missing required configuration")
	}
	return c, err
}
func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}
func run() error {
	path := flag.String("config", "/etc/familytraffic-exporter/config.json", "Exporter configuration")
	flag.Parse()
	cfg, err := load(*path)
	if err != nil {
		return err
	}
	state, err := journal.Open(cfg.StateDir, cfg.DetailBudget)
	if err != nil {
		return err
	}
	defer state.Close()
	conn, err := grpc.NewClient(cfg.API, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return err
	}
	defer conn.Close()
	client := xray.Client{RPC: command.NewStatsServiceClient(conn)}
	c := collector.New(state)
	tail := journal.Tailer{State: state, StartAtEnd: true}
	registry := prometheus.NewRegistry()
	registry.MustRegister(c, collectors.NewGoCollector(), collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}))
	var checkpointAge atomic.Int64
	registry.MustRegister(prometheus.NewGaugeFunc(prometheus.GaugeOpts{Name: "familytraffic_checkpoint_age_seconds", Help: "Age of the latest durable journal write."}, func() float64 { return time.Since(time.Unix(checkpointAge.Load(), 0)).Seconds() }))
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	var scrapeMu sync.Mutex
	poll := func() error {
		scrapeMu.Lock()
		defer scrapeMu.Unlock()
		now := time.Now()
		users := map[string]xray.Identity{}
		b, e := os.ReadFile(cfg.Identity)
		if e == nil {
			e = json.Unmarshal(b, &users)
		}
		c.Health("identity", e == nil, float64(now.Unix()))
		if e != nil {
			users = map[string]xray.Identity{}
		}
		deadline, cancel := context.WithTimeout(ctx, 5*time.Second)
		values, bad, e := client.Read(deadline, users)
		cancel()
		c.UpdateNative(values, e == nil, float64(now.Unix()))
		if bad > 0 {
			if e = state.Commit("", journal.Cursor{}, []journal.Event{{Metric: "familytraffic_parse_errors_total", Labels: map[string]string{"source": "xray"}, Value: float64(bad)}}, now); e != nil {
				return e
			}
		}
		identities := map[string]string{}
		for key, v := range users {
			identities[key] = v.UserID
		}
		for source, path := range cfg.Logs {
			e = tail.Poll(source, path, identities, now)
			c.Health(source, e == nil, float64(now.Unix()))
			if e != nil {
				log.Printf("source %s unavailable", source)
			}
		}
		if e = state.Failure(); e != nil {
			return e
		}
		if cfg.Fail2ban != "" {
			v, e := fail2ban.Read(cfg.Fail2ban, now)
			if e == nil && v.AuthUp {
				for protocol, count := range v.Auth {
					source := "helper_auth:" + protocol
					position := state.Position(source)
					delta := count - float64(position.Offset)
					events := []journal.Event{}
					if delta < 0 {
						delta = count
						events = append(events, journal.Event{Metric: "familytraffic_collection_gaps_total", Labels: map[string]string{"source": "auth", "reason": "helper_reset"}, Value: 1})
					}
					if delta > 0 {
						events = append(events, journal.Event{Metric: "familytraffic_auth_failures_total", Labels: map[string]string{"protocol": protocol}, Value: delta})
					}
					if len(events) > 0 || position.ID == "" {
						if err := state.Commit(source, journal.Cursor{ID: "counter", Offset: int64(count)}, events, now); err != nil {
							return err
						}
					}
				}
				position := state.Position("helper_auth_gaps")
				delta := v.AuthGaps - float64(position.Offset)
				if delta > 0 {
					if err := state.Commit("helper_auth_gaps", journal.Cursor{ID: "counter", Offset: int64(v.AuthGaps)}, []journal.Event{{Metric: "familytraffic_auth_collection_gaps_total", Value: delta}}, now); err != nil {
						return err
					}
				}
			}
			c.UpdateBans(v, e == nil, float64(now.Unix()))
		}
		if e = state.Expire(now); e != nil {
			return e
		}
		if info, e := os.Stat(filepath.Join(cfg.StateDir, "journal.jsonl")); e == nil {
			checkpointAge.Store(info.ModTime().Unix())
		}
		return nil
	}
	if err = poll(); err != nil {
		return err
	}
	failure := make(chan error, 1)
	pollDone := make(chan struct{})
	go func() {
		defer close(pollDone)
		ticker := time.NewTicker(15 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				if e := poll(); e != nil {
					failure <- e
					return
				}
			}
		}
	}()
	metrics := promhttp.HandlerFor(registry, promhttp.HandlerOpts{Timeout: 10 * time.Second, MaxRequestsInFlight: 2})
	mux := http.NewServeMux()
	mux.HandleFunc("/metrics", func(w http.ResponseWriter, r *http.Request) {
		scrapeMu.Lock()
		defer scrapeMu.Unlock()
		keys := c.InitializationKeys()
		status := &statusWriter{ResponseWriter: w, status: 200}
		metrics.ServeHTTP(status, r)
		if status.status == 200 && r.Context().Err() == nil {
			if err := state.Exposed(keys); err != nil {
				select {
				case failure <- err:
				default:
				}
			}
		}
	})
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) })
	server := &http.Server{Addr: cfg.Listen, Handler: mux, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 15 * time.Second, IdleTimeout: 30 * time.Second}
	go func() {
		e := server.ListenAndServe()
		if e != http.ErrServerClosed {
			select {
			case failure <- e:
			default:
			}
		}
	}()
	select {
	case <-ctx.Done():
	case err = <-failure:
		stop()
	}
	shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	server.Shutdown(shutdown)
	stop()
	<-pollDone
	return err
}
