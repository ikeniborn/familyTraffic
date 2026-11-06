---
chain:
  intent: docs/superpowers/intents/2026-11-05-proxy-vless-traffic-monitoring-intent.md
review:
  spec_hash: bb2646e2295223e9
  last_run: 2026-11-05
  phases:
    structure: { status: passed }
    coverage: { status: passed }
    clarity: { status: passed }
    consistency: { status: passed }
  findings: []
---
# Design: proxy-vless-traffic-monitoring

**Status:** approved

## Scope and acceptance
This design implements the user-approved reduced scope: native user/inbound byte counters, bounded client/destination access-event analytics, errors, Fail2ban, Prometheus-only history for 30 days, and Node · Traffic. No new Xray transfer-path patch is permitted. Stop before implementation.

## Status
This is the revised Prometheus-only design. It is not deployed. The user approved minimal Xray changes and requires a stop before implementation.

Use native Xray statistics and an external exporter. Keep 30-day metric history and Node · Traffic. Exact byte attribution per user/client/destination is removed from scope. PostgreSQL, SQL datasources, and new Xray transfer-path instrumentation are excluded.

## Verified baseline
Inspection and pinned-source review establish capability, not production test results.

The host runs Xray 24.11.30 Custom. The repository pins 98a72b6fb49bcc403c4cae1ff529b9def43e6ad8 with an existing authentication-journal patch. No new patch is planned. Native stats and API are disabled in the inspected configuration.

HTTP and SOCKS set the authenticated username as the native statistics email. VLESS generation uses username@vless.local. Resolve these identities through the managed registry; never infer a user from an IP.

There are three configured VLESS clients and three accounts per proxy inbound. Native user statistics are keyed by email, not inbound: identical HTTP/SOCKS usernames share a counter. Shared TLS/plaintext upstream ports also prevent their separation in those counters.

Nginx terminates TLS for HTTPS and SOCKS5S. Optional plaintext listeners route to the same Xray proxy inbounds. SOCKS UDP is currently disabled and remains disabled. Node Exporter monitoring already exists.

## Options and recommendation
Select the existing counters and logs as the scope boundary.

| Option | Outcome |
|---|---|
| Native counters only | Low cost; no address relationship analytics |
| Native counters plus bounded log-derived metrics | Selected: user/inbound bytes, address relationships by access-event count, errors and bans |
| New Xray stream instrumentation | Excluded: unnecessary complexity for the revised scope |

No byte allocation based on connection counts is allowed. A destination popularity chart counts access events, not bytes or website page views.

## Collection architecture
Run one external exporter on ikenibornsw and let central Prometheus scrape it.

Enable stats, StatsService and the required user/inbound/outbound policy flags. Use a loopback-only API listener and dedicated routing to the API service. Poll QueryStats with reset=false every 15 seconds. Exclude the API inbound from user-traffic dashboards.

Retain current proxy listeners and routing. Do not split inbounds or rename credentials to manufacture protocol-specific user counters.

Enable Xray access logging independently of FT_DEBUG. Keep warning-level errors. Tail access, authentication, error, Fail2ban, and a minimal Nginx stream access log. Nginx logs include listener port, client IP, session status, duration and sent/received bytes; no credentials or URLs.

The exporter serves /metrics from a dedicated port reachable only by the monitoring source. Reuse the established source-restriction pattern after verifying the actual scraper egress. Keep the API private. Run unprivileged; use restricted log groups and a narrowly scoped read-only Fail2ban helper.

## Byte and address contract
Show independent measurement boundaries explicitly.

Native user bytes are identified by account email. Export user and account_class=proxy|vless|unknown after registry mapping. HTTP and SOCKS are combined for a shared proxy account. Native inbound bytes distinguish HTTP, SOCKS and VLESS groups but not TLS variants sharing an inbound.

Nginx stream bytes distinguish public HTTPS/SOCKS5S/plaintext listeners. They are session-completion measurements at a different boundary and include different overhead. Never add Nginx and Xray bytes as one total.

Access metrics contain authenticated user when present, client IP, requested destination host/IP and inbound group. Remove URL paths, query strings, fragments and userinfo before labels. Normalize host case and IP representation. Do not infer a resolved peer address that the log does not provide.

Native access accepted means accepted/dispatched request, not confirmed end-to-end success. Count access events rather than claiming an exact number of TCP sessions. Preserve unknown identity. Original VLESS client IP preservation is a validation gate; if forwarding masks it, show unavailable rather than associating loopback with a real client.

## Delivery and failure semantics
Persist log offsets and derived counters together and expose source health.

Use a local journal and atomic checkpoints for offsets, counters and admitted label tuples. This is exporter recovery state, not another historical query database. Recover without duplicating processed records. Detect inode rotation, truncation, unread-file removal and parse failures. Emit gap metrics for unrecoverable data.

Publish native counters directly without resetting Xray. Exporter restarts must not reset Xray counters. An Xray restart can lose unsampled increments; Prometheus reset handling cannot reconstruct them. Detect source restarts and show the affected interval.

Retain derived counters after short sessions close. Initialize a new derived series at zero for one successful exposition cycle before publishing pending increments. HTTP exposition completion is not proof of Prometheus ingestion; scrape failures can still lose the baseline. Document first-sample undercount rather than claiming exact billing.

On source failure, omit stale traffic samples and expose source_up=0 plus last-success timestamp. Keep /metrics responsive. Never return a cached counter as if it were a new successful measurement. Collector or logging failures must not modify forwarding behavior.

## Storage and retention
Prometheus is the only historical metrics store. Target 30 days of history.

Set retention.time=30d on the actual server storing these samples, not an agent. Inspect current version, flags, disk and existing series before deployment. If retention.size is configured, provision enough space so it does not expire samples before 30 days. This change affects the shared TSDB and requires impact review.

Proposed budget: 10,000 admitted user/client/destination/inbound tuples per node over a rolling 30-day activity window, with one access counter per tuple. Retain admitted counters for 30 days after last activity; do not evict recently active tuples to make room. At the cap, keep low-cardinality totals and increment detail_overflow_total. Mark address analytics incomplete. The cap is an explicit reduced-scope detail limit.

Raw attempted usernames and arbitrary error messages never become labels. Add a separate bounded IP-ban family only for active IPs with a clear limit and overflow signal. Neither timestamps nor connection IDs are labels.

Capacity scenario: 10,000 continuously exposed series at 15 seconds produce 1.728 billion samples over 30 days. At an illustrative 1–2 bytes/sample, compressed samples alone are roughly 1.7–3.5 GB. Indexes, WAL, head memory, existing workloads and label churn are additional. This is not a sizing guarantee. Measure current resources and a representative label set before enabling detail.

Access logs can contain URL paths before sanitization. Use owner/group-restricted files, bounded rotation and a proposed 24-hour raw-log retention. Export no URL or credential fields. Review disk pressure and logging overhead before production rollout.

## Prometheus contract
Keep byte totals independent from address-event metrics.

Job: familytraffic; instance: ikenibornsw; proposed scrape/poll interval: 15 seconds.

| Metric | Type | Labels and meaning |
|---|---|---|
| familytraffic_user_bytes_total | counter | user_id, account_class, direction; native email counter |
| familytraffic_inbound_bytes_total | counter | inbound, direction; native inbound |
| familytraffic_frontend_bytes_total | counter | listener, direction; completed Nginx sessions |
| familytraffic_access_events_total | counter | user_id, client_ip, destination, inbound; bounded detail |
| familytraffic_access_total | counter | inbound, status; unbounded-event aggregate with bounded labels |
| familytraffic_errors_total | counter | source, reason; fixed reason enum |
| familytraffic_auth_failures_total | counter | protocol; existing auth journal |
| familytraffic_fail2ban_events_total | counter | jail, action; ban/unban/restore distinguished |
| familytraffic_fail2ban_banned | gauge | jail; current ban count |
| familytraffic_fail2ban_ip_banned | gauge | jail, client_ip; bounded current state |
| familytraffic_source_up | gauge | source |
| familytraffic_last_success_timestamp_seconds | gauge | source |
| familytraffic_collection_gaps_total | counter | source, reason |
| familytraffic_detail_series | gauge | family |
| familytraffic_detail_overflow_total | counter | family |
| familytraffic_parse_errors_total | counter | source |
| familytraffic_checkpoint_age_seconds | gauge | none |

Example user throughput: sum by (user_id, direction) (rate(familytraffic_user_bytes_total[5m])).
Example user volume: sum by (user_id, direction) (increase(familytraffic_user_bytes_total[24h])).
Example destinations: topk(20, sum by (destination) (increase(familytraffic_access_events_total[24h]))).

PromQL increase extrapolates interval edges. User volume is a monitoring estimate, not billing. Native Vision splice accounting may update after the raw-copy operation returns; long flows can produce delayed jumps. Label such rates as sampled counters and test this behavior before promising real-time bandwidth.

## Errors and blocking
Separate claimed identity, authenticated activity, and IP bans.

Parse FT_AUTH_FAILURE with its escaping and truncation rules. Classify protocol failures without promoting attempted usernames to authenticated users. Classify warning errors with bounded categories and an unknown category; parsing failures remain visible.

Checkpoint Fail2ban logs for ban/unban/restore counts. Read current status for gauges. Restore after restart is not a new attack ban. Reconcile jail count and detailed IP state without assuming missing logs mean zero bans.

Fail2ban blocks IPs, not accounts. An IP can serve multiple users behind NAT. Dashboard links to access activity are associations, not account-ban evidence.

TLS errors before authentication have no user. Ban events do not count rejected firewall packets. Do not present these unsupported quantities.

## Node · Traffic dashboard
All panels use the existing Prometheus datasource. Proposed UID: node-traffic.

| Row | Panels | Filter scope |
|---|---|---|
| Health | source status, freshness, gaps, detail overflow | node |
| Traffic | inbound upload/download and estimated interval volume | node, inbound |
| Users | proxy/VLESS user bytes, estimated rate, ranking | node, user, account class |
| Frontends | HTTPS/SOCKS5S/plaintext completed-session bytes and errors | node, listener |
| Addresses | user/client/destination access-event table; top clients and destinations | node, user, inbound, client, destination |
| Errors | authentication failures and error categories | node, protocol/source |
| Blocking | jail counts, active IPs, ban/unban/restore trends | node, jail |
| Exporter | CPU, RSS, scrape duration, checkpoint age, parser failures | node |

Use range-aware address discovery so inactive historical series remain selectable. Cap selector result sizes and offer typed filters. User or address filters must not silently affect panels that lack those labels. Mark per-user/protocol byte breakdown unavailable; do not filter combined proxy bytes as if they were HTTP-only.

Show gaps as unknown, not zero. No active-session count is inferred from access-start events without matching ends. Top-N is only a chart view; admitted detail remains queryable for its retention period.

## Alerts and operating procedures
Proposed alert thresholds require validation with the final deployment.

- Missing scrape or source for two minutes: inspect exporter, API reachability, permissions and log rotation.
- Checkpoint age above two minutes while events arrive: inspect disk and recovery state.
- Any new gap or overflow: mark affected detail incomplete and investigate capacity or parser failure.
- Detail series above 80 percent of budget: inspect destination churn before the cap.
- Low TSDB free space or early retention: reduce unrelated load or allocate capacity; do not silently shorten the promised history.
- Elevated auth failures or bans: inspect protocol/jail activity; do not automatically unban.

For a flat user graph, first check source health, user-policy flags and identity mapping. For a delayed VLESS jump, inspect the native accelerated-path limitation before diagnosing packet loss. Preserve raw evidence under its retention policy and record incomplete intervals.

## Acceptance and staged rollout
Stop before implementation. All checks below are future acceptance work, not completed test evidence.

1. Validate Xray configuration and private API routing. Verify stats reset=false and no public API exposure.
2. Exercise HTTP/HTTPS/SOCKS5/SOCKS5S/VLESS with known uploads/downloads. Confirm user, inbound and frontend boundaries independently.
3. Test shared HTTP/SOCKS usernames; verify combined user totals are not falsely split. Test VLESS email mapping.
4. Test Vision long flows and post-close counters. Verify that delayed updates are documented rather than repaired by changing transfer code.
5. Validate access fields, original client IP, URL sanitization, rotation, recovery, duplicate handling and new-series first-sample limitations.
6. Verify Fail2ban restore/restart semantics, active state and unknown-user handling.
7. Exercise label budgets and overflow. Verify summaries continue and detail completeness becomes false.
8. Measure baseline versus collection throughput, latency, CPU, RSS and disk growth. Propose rejection thresholds of more than 5 percent throughput loss or 10 percent p95 latency increase under repeated comparable load; approve thresholds before deployment.
9. Run promtool configuration/rule checks and dashboard query checks. Verify 30-day capacity against the shared TSDB.
10. After separate deployment permission, canary one host. Roll back by restoring previous config and removing only the new scrape/dashboard resources. Preserve existing auth protection and Node Exporter.

No new Xray source patch, production configuration, exporter or working dashboard has been created in this design stage.

## Evidence and decision checkpoint
The user accepted Prometheus-only and removal of mandatory tuple-level byte accounting. Final design approval and implementation permission remain separate.

Pinned source confirms authenticated usernames feed native user statistics for HTTP/SOCKS. The dispatcher keys user counters by email. The Vision raw-copy path updates counters after ReadFrom returns. These findings constrain the dashboard.

References:
- [Existing node monitoring](runbook/ikenibornsw-node-monitoring.md).
- [HTTP source](https://github.com/XTLS/Xray-core/blob/98a72b6fb49bcc403c4cae1ff529b9def43e6ad8/proxy/http/server.go).
- [SOCKS source](https://github.com/XTLS/Xray-core/blob/98a72b6fb49bcc403c4cae1ff529b9def43e6ad8/proxy/socks/server.go).
- [Dispatcher](https://github.com/XTLS/Xray-core/blob/98a72b6fb49bcc403c4cae1ff529b9def43e6ad8/app/dispatcher/default.go).
- [Vision accounting](https://github.com/XTLS/Xray-core/blob/98a72b6fb49bcc403c4cae1ff529b9def43e6ad8/proxy/proxy.go).
- [Prometheus storage](https://prometheus.io/docs/prometheus/latest/storage/).
- [Prometheus instrumentation](https://prometheus.io/docs/practices/instrumentation/).

Local evidence: lib/user_management.sh, lib/orchestrator.sh, lib/nginx_stream_generator.sh, and the existing auth-journal patch. Task: familyTraffic/reference/tasks/proxy-vless-traffic-monitoring.


## Acceptance (from intent)
- O1: The design identifies verified collection sources and gaps for HTTP, HTTPS, SOCKS5, SOCKS5S, and VLESS. It distinguishes proxy transport security from destination HTTPS traffic.
- O2: The design provides native user and inbound byte counters with upload/download dimensions, plus client/destination access-event analytics. It does not require byte attribution for a complete user/client/destination tuple or a user/protocol cross-product.
- O3: Prometheus retains metric history for 30 days. The design defines byte boundaries, estimated interval totals, address normalization, counter resets, series budgets and visible collection gaps.
- O4: Operators can review a separate Node · Traffic dashboard design with traffic, users, client addresses, destinations, errors, and blocking views. Each panel has a declared source and query strategy.
- O5: The design includes an additional exporter and Prometheus integration, with an explicit capacity estimate for tuple cardinality and retention. Prometheus is the only historical metrics store; no additional database or SQL datasource is included.
- O6: The minipc monitoring runbook presents verified current topology, proposed architecture, metric definitions, dashboard layout, validation, rollout, rollback, and troubleshooting procedures. Proposed behavior is distinguishable from deployed behavior.

- Done when: A reviewed minipc runbook maps O1–O6 to sources, design decisions, queries, capacity estimates, and future acceptance checks. It identifies remaining approval checkpoints and passes applicable documentation checks.
- Done when: The user can review the complete Node · Traffic layout and trace every required dimension to a collection and retention path. No deployed monitoring capability is claimed at this stage.
