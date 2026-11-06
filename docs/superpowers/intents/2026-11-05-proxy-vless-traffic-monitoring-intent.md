---
workflow:
  route: chain
  continuation: full
review:
  intent_hash: 569c268e3f1eb8ba
  last_run: 2026-11-05
  phases:
    structure: { status: passed }
    completeness: { status: passed }
    clarity: { status: passed }
    consistency: { status: passed }
    alignment: { status: passed }
  findings: []
---
# Intent: proxy-vless-traffic-monitoring

**Date:** 2026-11-05
**Scope revision:** User-approved Prometheus-only and minimal Xray changes; replaces mandatory tuple-byte accounting.
**Status:** approved

## Objective
Design traffic observability for the ikenibornsw proxy service and document the solution in the minipc monitoring runbook. Operators need to explain traffic consumption, connection errors, and Fail2ban blocks by user, client, and destination. This stage delivers research and design; implementation and deployment require subsequent approval.

## Desired Outcomes
- O1: The design identifies verified collection sources and gaps for HTTP, HTTPS, SOCKS5, SOCKS5S, and VLESS. It distinguishes proxy transport security from destination HTTPS traffic.
- O2: The design provides native user and inbound byte counters with upload/download dimensions, plus client/destination access-event analytics. It does not require byte attribution for a complete user/client/destination tuple or a user/protocol cross-product.
- O3: Prometheus retains metric history for 30 days. The design defines byte boundaries, estimated interval totals, address normalization, counter resets, series budgets and visible collection gaps.
- O4: Operators can review a separate Node · Traffic dashboard design with traffic, users, client addresses, destinations, errors, and blocking views. Each panel has a declared source and query strategy.
- O5: The design includes an additional exporter and Prometheus integration, with an explicit capacity estimate for tuple cardinality and retention. Prometheus is the only historical metrics store; no additional database or SQL datasource is included.
- O6: The minipc monitoring runbook presents verified current topology, proposed architecture, metric definitions, dashboard layout, validation, rollout, rollback, and troubleshooting procedures. Proposed behavior is distinguishable from deployed behavior.

## Health Metrics
- Preserve proxy throughput, connection latency, and successful connection rate. Define baseline and comparative measurements before implementation approval.
- Measure collection CPU, memory, disk growth, and scrape duration before deployment. This research stage must provide the measurement procedure and proposed acceptance thresholds; it must not claim measured overhead without evidence.
- Preserve existing Node Exporter and Prometheus monitoring. Read-only inspection must not restart production services or change runtime configuration.

## Strategic Context
- Interacts with: familyTraffic, the ikenibornsw proxy host, Xray, Fail2ban, Prometheus on minipc, Grafana, and the minipc monitoring runbook.
- Priority trade-off: Preserve service stability and accounting accuracy. Evaluate collection cost rather than silently dropping required detail.
- Existing baseline: minipc/runbook/ikenibornsw-node-monitoring documents Node Exporter scraping and source-restricted network access. System interface counters do not establish user-to-destination attribution.

## Constraints
### Steering
- Reuse the existing monitoring stack where verified capabilities satisfy the required detail.
- Prefer the smallest design that meets the observed service topology and the 30-day retention requirement.
- Document unsupported cases and evidence gaps explicitly.
### Hard
- Cover all five requested protocol variants and both address dimensions.
- Use native Xray counters and logs. Do not add new Xray transfer-path instrumentation or modify Vision.
- Retain admitted metrics for 30 days. Define explicit label budgets and mark overflow as incomplete analytics; never silently present top-N as full coverage.
- Keep implementation, deployment, production configuration changes, and active load tests outside this stage.
- Exclude passwords, tokens, private keys, and authentication headers from documentation and proposed metric labels.
- Store the monitoring runbook in the minipc domain. Preserve the configured project binding.

## Autonomy Zones
- Full autonomy: Read documentation, inspect repository and authorized host state, research official sources, and prepare draft artifacts.
- Guarded: Record evidence and limitations when inspecting production metadata or estimating collection cost. Redact credentials.
- Proposal-first: Obtain approval for the checked intent, the full design continuation, and the resulting architecture before implementation.
- No autonomy: Deploy changes, restart production services, alter access grants, or run production load tests during this stage.

## Stop Rules
- Halt if: Required access is denied or inspection would require production mutation.
- Escalate if: A required native metric is unavailable, or the reduced design would require new proxy instrumentation or another historical storage system. Present evidence and alternatives without weakening the requirement.
- Done when: A reviewed minipc runbook maps O1–O6 to sources, design decisions, queries, capacity estimates, and future acceptance checks. It identifies remaining approval checkpoints and passes applicable documentation checks.
- Done when: The user can review the complete Node · Traffic layout and trace every required dimension to a collection and retention path. No deployed monitoring capability is claimed at this stage.
