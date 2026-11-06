# Proxy traffic monitoring verification

## Delivered scope

Prometheus-only monitoring on ikenibornsw, with native Xray user/inbound bytes, bounded access-event address analytics, protected authentication and Fail2ban metrics, and Node · Traffic. Xray transfer paths and the existing custom image are unchanged.

## Test evidence

The implementation worker ran the following checks and returned successful results. Focused checks cover later parser, rotation and expiry changes without repeating unrelated full-suite evidence.

| Check | Result |
|---|---|
| Go exporter race tests | Passed; focused journal/collector tests cover final corrections |
| Bats unit suite | 138 cases; 2 expected root-only skips |
| ShellCheck | 191 baseline findings; 0 errors |
| Existing security lab | 11 real scenarios and 19 migration cases passed |
| Dashboard tests | 6 passed |
| Prometheus rules | 7 rules; 9 fixture scenarios passed with promtool 3.11.3 |
| Dashboard/template expressions | 39 expressions parsed successfully |
| Protocol lab | HTTP/HTTPS/SOCKS5/SOCKS5S/VLESS upload and download passed |

The enhanced artifact at tests/monitoring/artifacts/ft-traffic-1793944353-3462522/acceptance.json established:

- HTTP access/detail counts 100; SOCKS 4; VLESS 2.
- Native proxy download delta 407,604,048 bytes exceeds the known payload floor 406,847,488 bytes.
- Native VLESS download delta 1,054,044 bytes exceeds the 1,048,576-byte payload floor. Upload floors also passed.
- All 21 durable counter samples are equal across exporter restart.
- A 4 MiB Vision stream lasted 31.53 seconds; the download counter changed from 1,054,044 before to 1,067,509 during and 5,256,001 after.
- Three comparative workloads per mode each transferred 32 requests of 4 MiB. Median throughput changed from 130.95 to 131.42 MB/s (+0.36%); request p95 changed from 31.314 to 31.806 ms (+1.57%). CPU increased from 1.325 to 1.364 CPU-seconds; aggregate proxy RSS changed from 537.72 to 542.00 MB; log/state growth was 23,364 bytes. Exporter RSS measured through its Prometheus process metric was 15,425,536 bytes. The temporary laboratory executable name was not matched by the process-list filter; this fallback is recorded explicitly.

These local measurements do not guarantee Internet or production throughput. Native counters include boundary-specific overhead. PromQL increase estimates interval edges.

## Runtime verification

- familytraffic-exporter is active; observed service memory is approximately 5.3 MiB.
- Prometheus returns up=1 for job familytraffic and all eight source gauges are 1.
- Existing Node Exporter remains up=1.
- The actual Prometheus server confirms storage.tsdb.retention.time=30d.
- Grafana provisioned dashboard UID node-traffic, title Node · Traffic, with 33 panel/row objects and the existing Prometheus datasource.
- Live authenticated HTTP, HTTPS and SOCKS5 smoke requests returned HTTP 200.
- Native user-byte samples and HTTP/SOCKS address-event samples are present in central Prometheus.
- auth.log remains mode 0600. The native Stats API is loopback-only. UFW restricts exporter port 9915 to the established monitoring source.

## Recovery and known limits

Deployment backups are root-only under /opt/familytraffic/backup/traffic-monitoring-20261106 and /opt/minipc-traefik/backup-traffic-monitoring-20261106. Restore generated configurations and disable only the new monitoring resources to roll back.

HTTP/SOCKS address log records on the pinned build omit the authenticated email. Their address analytics therefore show unknown user; native per-user byte counters remain available. Shared HTTP/SOCKS credentials merge user-byte counters. Vision counters can update late. Address labels have an explicit admission budget; overflow and rotation gaps remain visible. No byte allocation to destinations is inferred.

Independent review corrected initial WAL directory durability, helper counter initialization, first-rotation visibility and HTTP CONNECT authority parsing. A clean-checkout CI failure also exposed ignored dashboard/config JSON files; both are now tracked with narrow ignore exceptions.

Final integration evidence and the authoritative lifecycle are recorded on familyTraffic/reference/tasks/proxy-vless-traffic-monitoring. The operational runbook is minipc/runbook/proxy-vless-traffic-monitoring.
