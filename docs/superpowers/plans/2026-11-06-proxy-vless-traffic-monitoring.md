---
result_check:
  verdict: OK
  source: plan
  plan_hash: 2317eb0ed3b3b27f
  last_run: 2026-11-06
  reviewed: true
  docs_checked: true
chain:
  intent: docs/superpowers/intents/2026-11-05-proxy-vless-traffic-monitoring-intent.md
  spec: docs/superpowers/specs/2026-11-05-proxy-vless-traffic-monitoring-design.md
review:
  plan_hash: 2317eb0ed3b3b27f
  last_run: 2026-11-06
  phases:
    structure: { status: passed }
    coverage: { status: passed }
    dependencies: { status: passed }
    verifiability: { status: passed }
    consistency: { status: passed }
  findings: []
---
# Node · Traffic Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans for authorized inline execution. Use superpowers:subagent-driven-development only after explicit delegation authorization. Do not execute this plan before the human checkpoint.

**Goal:** Deliver native traffic metrics and bounded address analytics through Prometheus, with a separate Node · Traffic dashboard.

**Architecture:** An independent host exporter reads the private Xray Stats API and local journals. It exposes native counters, durable log-derived counters, and source health. Central Prometheus stores 30 days of samples; Grafana uses its existing Prometheus datasource.

**Tech Stack:** Existing pinned Xray and Nginx; a Go exporter using the pinned Xray StatsService protobuf client and the Prometheus Go client; systemd; Prometheus; Grafana; existing Bash/Bats validation.

**Spec:** docs/superpowers/specs/2026-11-05-proxy-vless-traffic-monitoring-design.md

## Global Constraints

- Prometheus is the only historical metrics store.
- Keep 30-day metric history and Node · Traffic.
- Exact byte attribution per user/client/destination is removed from scope.
- PostgreSQL, SQL datasources, and new Xray transfer-path instrumentation are excluded.
- Retain current proxy listeners and routing.
- Poll QueryStats with reset=false every 15 seconds.
- Keep warning-level errors.
- Proposed budget: 10,000 admitted user/client/destination/inbound tuples per node over a rolling 30-day activity window.
- Preserve existing authentication protection and Node Exporter monitoring.
- Stop before implementation and obtain separate explicit permission.
- Treat all verification commands below as future work. No runtime acceptance results exist yet.

## Human checkpoints and prerequisites

H0 blocks every implementation task. H1 blocks production changes independently.

- [ ] H0: Obtain approval for this checked plan and explicit permission to implement locally.
- [ ] Resolve the base and PR target because both master and test branches exist. Ask the user under AGENTS.md branch policy.
- [ ] Check existing dev-* branches. Create dev-proxy-vless-traffic-monitoring from the selected current base. Apply the required worktree choice if another dev-* exists.
- [ ] Commit the approved intent, specification, profile and approved plan on that branch. Do not commit to master.
- [ ] Record baseline revision and tool versions. Verify the installed Go toolchain against the pinned Xray module before selecting compatible dependency versions; commit go.mod/go.sum and use locked builds.
- [ ] H1: Obtain separate production deployment permission after laboratory and regression evidence passes. Agree performance thresholds and the shared TSDB capacity change before H1.

## File ownership and interfaces

All paths are proposed deliverables unless explicitly marked existing. Keep one implementation owner per task.

| Path | Responsibility |
|---|---|
| lib/traffic_monitoring.sh | Generate opt-in stats/log configuration and safe enable/disable changes |
| lib/orchestrator.sh, lib/nginx_stream_generator.sh (existing) | Call the configuration helper without changing proxy listeners |
| docker-compose.yml (existing) | Add the Nginx log host mount required by the exporter |
| monitoring/exporter/go.mod, go.sum | Exporter dependencies and locked versions |
| monitoring/exporter/cmd/familytraffic-exporter/main.go | Process lifecycle, poll loop and HTTP endpoint |
| monitoring/exporter/internal/xray/client.go | Non-resetting StatsService reads and identity mapping |
| monitoring/exporter/internal/journal/parser.go, state.go | Sanitized event parsing, admission and crash-safe offset/counter recovery |
| monitoring/exporter/internal/collector/collector.go | Metric definitions and immutable scrape snapshots |
| monitoring/exporter/internal/fail2ban/client.go | Read sanitized helper state with a timeout |
| monitoring/systemd/familytraffic-exporter.service | Unprivileged host service and state directory |
| monitoring/systemd/familytraffic-fail2ban-snapshot.service, .timer | Root-owned fixed-command snapshot of jail state |
| monitoring/helpers/fail2ban_snapshot.py | Emit only jail and banned-IP data through atomic file replacement |
| monitoring/prometheus/familytraffic.rules.yml | Alerts and optional bounded summary recording rules |
| monitoring/prometheus/familytraffic.rules.test.yml | promtool rule fixtures |
| monitoring/prometheus/familytraffic.scrape.yml | Reviewed scrape fragment, not a replacement central config |
| monitoring/grafana/node-traffic.json | Dashboard UID node-traffic |
| tests/unit/test_traffic_monitoring.bats | Generator, listener, policy and rollback assertions |
| tests/monitoring/ | Lab integration, dashboard and configuration validation |

Interfaces: the API reader returns native named uint64 counters and a source timestamp. Parsers return typed events with normalized fields, byte offsets and file identity. The journal commits event effects and offsets together. Collectors publish immutable snapshots and separate source health. No module receives proxy credentials.

## Task 1: Native API and logging configuration

Closes O1/O2: exposes existing statistics and metadata without modifying Xray source. Uses existing configuration generators.

- [ ] Add fixture-driven Bats cases before changing generators. Assert unchanged proxy endpoints, account entries, routing order and warning log level.
- [ ] Add the helper and opt-in integration. Reserve loopback API port 10085 only after a collision check. Add stats={}, StatsService, user uplink/downlink flags at the actual configured levels, and inbound/outbound flags.
- [ ] Place the API routing rule before broad routing rules. Preserve all prior rules and exclude the API tag from dashboards.
- [ ] Configure access.log independently from FT_DEBUG. Add a JSON-escaped Nginx stream log format containing only timestamp, listener, client IP, status, duration and stream bytes. Mount its directory on the host.
- [ ] Generate a credential-free identity map from managed account names and VLESS emails. Do not give the exporter read access to users.json or the complete Xray config.
- [ ] Add restricted log permissions, bounded rotation and a 24-hour raw-log expiration policy. Document that raw Xray access output may contain URL fields before exporter sanitization.
- [ ] Validate generated configurations inside an isolated container with the current image. Demonstrate that disabling monitoring restores prior generated behavior.

Example invariant for the Bats test:

```bash
jq -e '.api.services == ["StatsService"] and (.inbounds[] | select(.tag == "traffic-api") | .listen == "127.0.0.1")' "$generated_config"
```

Run from the repository root:

```bash
bash -n lib/traffic_monitoring.sh lib/orchestrator.sh lib/nginx_stream_generator.sh
bats tests/unit/test_traffic_monitoring.bats tests/unit/test_proxy_source_ip.bats tests/unit/test_proxy_state.bats
```

Expected: all focused cases pass; generated Xray and Nginx configurations validate; no new public API listener or account mutation.

## Task 2: Native counters and exporter endpoint

Closes O2/O5: exposes byte counters and source health with honest measurement boundaries. Depends on Task 1 API contract.

- [ ] Create the Go module and mock StatsService tests. Check that QueryStats sends reset=false, handles timeout, and preserves a decrease after Xray restart rather than inventing bytes.
- [ ] Implement client.go using the pinned protobuf service. Parse only documented user/inbound/outbound traffic names. Reject malformed records with a parser-error count.
- [ ] Map username and username@vless.local through the sanitized registry. Emit proxy versus VLESS account classes. Never split shared HTTP/SOCKS counters by protocol.
- [ ] Implement the collector and /metrics. Poll every 15 seconds with a five-second API timeout; use a bounded snapshot so scrapes do not perform remote calls.
- [ ] On poll failure, omit the failed source's traffic samples. Publish source_up=0 and last-success timestamp. Do not expose a fresh-looking cached total.
- [ ] Test parallel scrapes, shutdown cancellation, an empty API response, user removal and registry refresh.

Essential test assertion:

```go
if request.Reset { t.Fatal("collector must not reset Xray statistics") }
```

Verification:

```bash
go -C monitoring/exporter test -race ./internal/xray ./internal/collector
go -C monitoring/exporter build ./cmd/familytraffic-exporter
```

Expected: race-free tests pass; native user and inbound metrics match fixture counters; failure produces unavailable rather than zero traffic.

## Task 3: Durable log-derived analytics

Closes O2/O3/O4: adds address-event analytics and frontend byte counters. Depends on Task 2 metric collector interfaces.

- [ ] Create fixtures for HTTP URLs, CONNECT, SOCKS, VLESS, IPv4/IPv6, absent users, malicious label input, Nginx session completion and malformed records.
- [ ] Implement URL parsing that retains only normalized host and optional explicit port. Discard userinfo, path, query and fragment before metric construction. Reject oversized/malformed fields without copying raw input to logs.
- [ ] Add access-event counters with user/client/destination/inbound labels. Export aggregate access totals independently so detail admission cannot drop summary events.
- [ ] Implement a single-writer journal with monotonically numbered records. Commit counter changes, label admission and file offsets together. Recover from a partial tail; atomically checkpoint using a temporary file, fsync and rename. Tests must interrupt each persistence boundary.
- [ ] Track file device/inode/offset. Drain renamed files before switching; detect truncation and removed unread data. Count gaps; do not claim exactly-once recovery when source data vanished.
- [ ] Admit at most 10,000 detail tuples. Retain each until 30 days after last activity. Count overflow and preserve summaries. New tuples are not a reason to evict recent history.
- [ ] Expose a new derived counter at zero for one exposition cycle before pending increments. Persist initialization state. Test and document that exposition completion does not prove scrape ingestion.
- [ ] Persist completed-session Nginx byte counters separately from native Xray counters. Do not sum the two boundaries.

Fixture expectation:

```text
input destination: https://name:secret@example.org/private?q=secret
metric destination: example.org
forbidden exposition substrings: private, secret, name:
```

Verification:

```bash
go -C monitoring/exporter test -race ./internal/journal ./internal/collector
```

Expected: deterministic replay adds each committed event once; truncation/loss raises gaps; overflow leaves aggregate totals correct; no URL secrets appear in exposition.

## Task 4: Errors, Fail2ban and host packaging

Closes O4/O5: supplies errors and current/historical blocking with least privilege. Depends on Tasks 2–3.

- [ ] Add auth-journal escaping/truncation fixtures and fixed error categories with unknown. Do not use attempted usernames as metric labels or authenticated identity.
- [ ] Parse ban/unban/restore as distinct actions with durable offsets. Test restart and log rotation independently from current-state reads.
- [ ] Implement a root-owned helper with a fixed jail list and fixed executable paths. It invokes only read-only Fail2ban status commands with timeouts and reads the existing mode-0600 auth journal to aggregate protocol-only auth counters. Persist journal identity/offset and aggregate counters crash-safely, then atomically publish a sanitized snapshot. Do not chmod or add ACL access to auth.log. No caller arguments or arbitrary command execution are accepted.
- [ ] Schedule the helper every 15 seconds. Mark snapshots older than 60 seconds unavailable. A failed helper must not overwrite valid state with a false empty ban list.
- [ ] Cap detailed active-IP series at 1,000 per node, publish overflow, and keep jail totals complete. Do not label banned IPs as banned users.
- [ ] Package the exporter as an unprivileged systemd service with a private state directory, read-only input access and no Docker socket. Keep executable/config files root-owned.
- [ ] Check port 9915 availability before proposing it as the exporter endpoint. Add access only for the verified Prometheus source during authorized deployment.

Verification:

```bash
python3 -m unittest discover -s tests/monitoring -p 'test_fail2ban_*.py'
go -C monitoring/exporter test -race ./internal/fail2ban ./internal/journal
systemd-analyze verify monitoring/systemd/familytraffic-exporter.service monitoring/systemd/familytraffic-fail2ban-snapshot.service monitoring/systemd/familytraffic-fail2ban-snapshot.timer
```

Expected: helper cannot mutate bans; missing/stale data becomes unknown; exporter runs without root or secret-file access.

## Task 5: Prometheus rules, retention and Node · Traffic

Closes O3/O4/O5: renders the agreed analytics using only Prometheus. Depends on Tasks 2–4 metric names.

- [ ] Create scrape/rule fixtures and dashboard JSON with UID node-traffic and title Node · Traffic. Reuse the existing Prometheus datasource UID discovered read-only at implementation time; do not create a SQL datasource.
- [ ] Add health, inbound traffic, users, frontend sessions, addresses, errors, blocking and exporter rows from the specification. Explain merged proxy users and delayed Vision counters in panel descriptions.
- [ ] Use rate for throughput and increase for estimated volumes. Address popularity uses access events. Declare variable scope per panel; user/client/destination filters cannot affect metrics lacking those labels.
- [ ] Use range-aware series queries for historical address selectors. Bound selector output and support typed filters. Show completeness/overflow beside address charts.
- [ ] Add two-minute availability alerts, detail-budget alerts, gaps/overflow alerts and checkpoint-stall alerts conditioned on arriving events. Missing data must not become zero through unconditional or vector(0).
- [ ] Inspect central Prometheus server version, retention flags, disk and active-series budget. Prepare a minimal 30d retention change and capacity report; do not apply it before H1.
- [ ] Preserve central config bind-mount behavior and existing scrape jobs. Stage the fragment and use promtool with the installed Prometheus version.

Representative query:

```promql
sum by (user_id, direction) (rate(familytraffic_user_bytes_total[5m]))
```

Verification:

```bash
promtool check rules monitoring/prometheus/familytraffic.rules.yml
promtool test rules monitoring/prometheus/familytraffic.rules.test.yml
python3 -m unittest discover -s tests/monitoring -p 'test_dashboard_*.py'
```

Expected: every required row has a valid query/source; unavailable sources are shown explicitly; no panel fabricates tuple-byte allocation; capacity covers 30 days plus existing workloads and headroom.

## Task 6: Protocol laboratory and regression evidence

Closes O1–O6 acceptance. Depends on Tasks 1–5. Runs only in an isolated local lab until H1.

- [ ] Extend tests/monitoring/ with a compose lab using the existing pinned image, exporter and Prometheus. Provide generated disposable credentials and a deterministic upload/download origin. Never reuse production credentials.
- [ ] Exercise HTTP, HTTPS, SOCKS5, SOCKS5S and VLESS. Verify exact fixture counts for derived events and expected increases in native counters; account for measurement-boundary overhead rather than comparing to interface bytes.
- [ ] Exercise identical HTTP/SOCKS usernames, shared NAT, IPv6, unknown identity, short sessions, Xray restart, collector restart, failed scrapes and destination churn.
- [ ] Exercise a long Vision flow before and after close. Record observed counter timing; do not modify Vision to improve the chart.
- [ ] Check whether VLESS original client IP survives forwarding. If absent, keep unavailable and return any forwarding change to design review.
- [ ] Compare baseline and instrumented throughput, p95 latency, CPU, RSS and disk growth under repeatable load. Review proposed 5 percent throughput/10 percent latency thresholds before deployment.
- [ ] Add exporter and monitoring checks to .github/workflows/lint-and-test.yml. Preserve the existing pinned-image security lab and Bash checks.
- [ ] Run focused failures narrowly during iteration. Run the final applicable full CI suite once for the final code fingerprint and retain evidence.

Commands to be supported by the new lab runner:

```bash
bash tests/monitoring/run.sh
go -C monitoring/exporter test -race ./...
bats --print-output-on-failure tests/unit/
bash tests/lint.sh
bash tests/security_lab/run.sh --image familytraffic:proxy-security
```

Expected: protocol matrix, durable recovery and rules pass; performance results and known gaps are reported. A failed mandatory acceptance check blocks deployment; a green unit suite alone does not establish outcome compliance.

## Task 7: Reviewed rollout and documentation closure

Closes O6 operational delivery. Depends on all acceptance evidence and H1.

- [ ] Present the final diff, test fingerprint, performance/capacity results, source-address rule and rollback procedure for deployment approval.
- [ ] After H1, back up generated configs and central monitoring files. Validate before reload; deploy one host only.
- [ ] Confirm scrape up, source health, the five protocol-family views, existing Node Exporter health and dashboard query results. Inspect missing/overflow indicators.
- [ ] If acceptance fails, restore the previous generated configs and disable only the new exporter/scrape resources. Preserve the existing auth-journal patch, firewall protection and prior dashboards.
- [ ] Update minipc/runbook/proxy-vless-traffic-monitoring with actual versions, paths, commands, thresholds, results and rollback evidence. Separate delivered behavior from remaining proposals.
- [ ] Run the required code-graph update/publication route and scenario resolution when applicable. Record tests and repository revision in the task ledger.
- [ ] Run check-chain result against this plan before branch finishing. Do not mark the task done while implementation or delivery remains pending.

Expected: deployed behavior is evidenced or rolled back explicitly. The task ledger records the actual outcome, not a planned success.

## Coverage and verification economy

| Spec commitment | Plan coverage |
|---|---|
| Native counters and unchanged transfer paths | Tasks 1–2, 6 |
| User identity and measurement boundaries | Tasks 2–3, 5–6 |
| Address events, privacy, 30-day budgets | Tasks 3, 5–6 |
| Recovery, gaps and unavailable data | Tasks 2–4, 6 |
| Errors and IP blocking | Tasks 4–6 |
| Node · Traffic and Prometheus-only retention | Task 5 |
| Stability and resource overhead | Task 6, H1 |
| Runbook, rollback and separate permission | H0/H1, Task 7 |

Planning validation is documentation-only. Runtime commands above are not executed while preparing this plan. Each future verification record must include command, exit code, scope and code fingerprint.
