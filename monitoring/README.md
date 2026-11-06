# Node · Traffic monitoring

The exporter reads native Xray counters and local metadata. It never resets native statistics. HTTP and SOCKS with one login share the proxy-user counter. Address popularity counts access events, not traffic bytes. Native Vision counters can update only after a long copy finishes. PromQL interval byte totals are monitoring estimates.

## Build and checks

Use the module's locked dependencies. The build uses the same Xray source revision as the server protobuf API.

```bash
CGO_ENABLED=0 go -C monitoring/exporter build -trimpath -o /tmp/familytraffic-exporter ./cmd/familytraffic-exporter
go -C monitoring/exporter test -race ./...
python3 -m unittest discover -s tests/monitoring -p 'test_*.py'
bats tests/unit/test_traffic_monitoring.bats
bash tests/monitoring/run.sh
```

The lab requires Docker, Compose, and an existing application image. It defaults to familytraffic:proxy-auth-username; override FT_TRAFFIC_IMAGE for CI. It creates disposable credentials, an internal network, a local TLS origin and VLESS Vision client. It records sanitized protocol and metric evidence under tests/monitoring/artifacts. Local short-flow timing is observational and does not establish production throughput guarantees.

## Installation boundaries

Install the static binary as /usr/local/bin/familytraffic-exporter. Create an unprivileged familytraffic-exporter user and familytraffic-monitoring group. Install config.example.json as /etc/familytraffic-exporter/config.json and systemd files from monitoring/systemd. The exporter uses a private state directory; it requires no Docker socket or access to the complete proxy config/database.

Use stage_traffic_monitoring_config from lib/traffic_monitoring.sh with FT_TRAFFIC_MONITORING=true to stage the active Xray config. Validate with the installed Xray before replacing the active file. Use refresh_traffic_identity_map to create /opt/familytraffic/config/traffic-identities.json. It contains managed names only. The user-management reload path refreshes this map when monitoring is enabled.

Nginx generation supports FT_TRAFFIC_MONITORING=true independently of FT_DEBUG. Keep current listeners and routing. Mount /opt/familytraffic/logs/nginx at /var/log/nginx. Validate Nginx config before reloading. Apply generated configuration with existing bind-mount inode conventions.

The exporter endpoint is proposed at TCP9915. Verify availability and restrict access to the actual Prometheus source. The Stats API binds only 127.0.0.1:10085. Check for port conflicts before activation.

## Protected authentication journal

Keep auth.log owned by root with mode0600. The existing Xray authentication journal rejects any different mode. Do not grant exporter ACLs on that file.

The root-owned fixed-command helper reads that journal and Fail2ban status. It atomically writes sanitized counter totals, offsets and jail state into /var/lib/familytraffic-fail2ban/status.json. No attempted usernames or passwords are written. The snapshot is root:familytraffic-monitoring0640. The exporter reads only this snapshot. Helper authentication counters pass through the exporter's durable zero-baseline mechanism.

Allow exporter read access to access.log, error.log, Nginx traffic.log and Fail2ban event log. Reapply any narrowly scoped read permission after log rotation; do not give unrestricted access to authentication databases. Keep the host log directories searchable by the monitoring group. The Fail2ban snapshot helper service uses Group=familytraffic-monitoring and a dedicated state directory.

## Recovery and rotation

On first startup, production tailers and the authentication helper start at the current file end. Existing log records are not backdated into present metrics. Subsequent starts restore committed offsets and counters. This intentionally starts monitoring history at deployment.

The journal records offset/counter transactions with fsync. Checkpoints use write, fsync, atomic rename and directory fsync. Startup ignores a partial final journal record; malformed complete records fail startup. Uncertain write/sync durability poisons the state and stops collection rather than reusing a sequence.

Use the dedicated rotation config outside /etc/logrotate.d and the supplied 15-minute timer. Reconcile existing rotation stanzas first: do not rotate access.log twice. Keep the existing auth/error protection. Emit traffic-rotation-generation markers in both log directories. copytruncate can lose data between truncation and writer activity; every observed generation change explicitly marks possible loss even when the file grew beyond its previous offset. It is not lossless accounting. Any independent auth-journal copytruncate rotation must emit the same Xray-directory marker.

The proposed raw traffic-log policy is hourly rotation, maximum24 files, maximum age1day and maximum10MiB per check. A burst can exceed this between checks. Retention is bounded metadata for recovery, not historical analytics. Prometheus retains metric history for30days, subject to capacity and size limits.

## Central configuration

Merge the scrape fragment and rule file into the existing Prometheus configuration. Use the actual installed Prometheus version for promtool checks. Set server TSDB retention to30d only after reviewing the shared disk/memory budget; an agent retention setting does not provide central history. A smaller retention.size can expire data early.

Import node-traffic.json using the existing Prometheus datasource. It uses a datasource variable. Configure the existing datasource UID at provisioning. Maintain source freshness and completeness panels. User/client/destination selectors apply only to panels carrying those labels.

## Rollback

Restore the previous generated Xray and Nginx configurations and validate them before reload. Disable only the new exporter/helper/rotation units and remove the new scrape job/rules/dashboard. Preserve prior Node Exporter metrics, authentication protection and Fail2ban rules. Retain the journal and deployment backups for investigation. Never remove other Prometheus jobs to recover this feature.
