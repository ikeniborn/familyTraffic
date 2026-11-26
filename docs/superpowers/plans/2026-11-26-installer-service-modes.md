---
chain:
  intent: docs/superpowers/intents/2026-11-26-installer-service-modes-intent.md
  spec: docs/superpowers/specs/2026-11-26-installer-service-modes-design.md
review:
  plan_hash: 747a0296f0e1f168
  last_run: 2026-11-26
  phases:
    structure: { status: passed }
    coverage: { status: passed }
    dependencies: { status: passed }
    verifiability: { status: passed }
    consistency: { status: passed }
  findings: []
---
# Installer service modes implementation plan

**Goal.** Install VPN only, proxy only, or both. Use the selected public endpoints consistently across the server lifecycle.

**Architecture.** Resolve the service settings once per operation. Use the existing deployment environment file for persistence. Derive nginx listeners, Xray receivers, access rules, exports and checks from the same selection.

**Tech stack.** Bash, jq, nginx stream, Xray, Docker Compose, UFW, fail2ban, Go, Bats and Python.

**Spec.** [Approved design](../specs/2026-11-26-installer-service-modes-design.md). **Intent.** [Approved outcomes](../intents/2026-11-26-installer-service-modes-intent.md).

## Global constraints

Use the existing feature branch based on `test`. Execute the tasks in order in this session with `superpowers:executing-plans` if the operator selects inline execution. The tasks share the deployment settings and generated configuration.

Keep the internal Reality port distinct from its public port. Preserve SSH, operator firewall rules, TLS renewal, access restrictions, account rollback and existing working links. Preserve the saved-user installation guard. Keep mode switching and the proposed landing page outside this release.

For each behavior change, add the failing case first. Run its focused check before and after the change. Record the command, revision, working-tree fingerprint, exit code and outcome. Run syntax checks on changed shell files. Reuse evidence while the inputs match.

### Task 1. Resolve new and legacy deployment settings

**Result.** Every caller obtains the same mode, public ports and transport schemes. A conflicting installation can still serve traffic.

- [ ] Create `lib/service_modes.sh` and `tests/unit/test_service_modes.bats`. Define `load_service_settings ROOT` for installed state and `validate_service_settings` for the resolved variables. Keep parsing data-only. Return nonzero with the relevant file and field on ambiguity.
- [ ] Cover all six fields in the design, empty disabled ports, required active ports, partial new settings and contradictory duplicate keys. For example, `FT_SERVICE_MODE=proxy` with HTTPS port 443 and empty SOCKS and VPN ports must resolve to one public TLS endpoint.
- [ ] Use fixtures for legacy VPN, combined, plaintext-only, custom identifiable ports and a conflicting nginx route. Match managed flags, routes and actual Xray receivers. Recognize unused listeners from the known VPN-only template. Preserve supported plaintext-only layouts and their schemes without inventing TLS endpoints.
- [ ] Keep the resolver read-only. Compare fixture hashes before and after successful and refused reads. Include an unrelated read-only command on a conflicting fixture.

```bash
bats tests/unit/test_service_modes.bats tests/unit/test_proxy_state.bats
```

Expected evidence includes the endpoint matrix and a named conflict without file changes.

### Task 2. Select and validate the fresh installation

**Depends on Task 1. Result.** The operator sees only applicable questions and approves a conflict-free setting before host changes.

- [ ] Extend `lib/interactive_params.sh` and `install.sh`. Select mode first. Enter selects VPN only. In proxy modes select SOCKS and optional plaintext explicitly. Prompt for each enabled external port, show schemes and summarize the final choice. Keep existing unattended inputs working.
- [ ] Validate the complete choice against decimal range, duplicates, reserved management and backend ports, ACME, optional services and active IPv4/IPv6 sockets. Separate this fresh-host occupancy check from reading a running installation. Validate late MTProxy selection before setup. Preserve the existing-install guard before cleanup and keep rejected inputs ahead of service and UFW mutations.
- [ ] In `lib/orchestrator.sh`, make the selection available before generation. Persist all selected fields and compatible legacy flags together, preserving unrelated keys and file permissions. Exercise a failed save and retry. Limit Reality inputs and key generation to VPN modes. Preserve the certificate path for TLS proxy installations.
- [ ] Extend `tests/unit/test_installer_runtime.bats` with scripted answers for default and custom ports. Stub host-changing commands and assert zero calls on invalid input. Include port 0, 65536, a duplicated active port, an occupied IPv6 port and an SSH collision.

```bash
bats tests/unit/test_installer_runtime.bats tests/unit/test_install_acme.bats tests/unit/test_installer_security_setup.bats
```

Expected evidence includes a saved proxy-only configuration with HTTPS on 443 and no request for Reality parameters.

### Task 3. Generate the selected listeners and protect every receiver

**Depends on Tasks 1–2. Result.** An HTTPS-only proxy starts with one authenticated receiver. Removing its last user restores closed access.

- [ ] Update `lib/nginx_stream_generator.sh` and `lib/orchestrator.sh`. Route VPN through the selected public VPN port. Terminate proxy TLS on the selected proxy ports. Emit only selected public listeners and internal receivers. Keep PROXY protocol, loopback protection, Tier 2 routing and ACME where applicable. Verify VPN-only nginx starts without requiring a proxy-domain certificate.
- [ ] In `lib/proxy_security.sh` and `lib/user_management.sh`, replace the hardcoded pair requirement with an exact comparison to the selected receiver set. Reject missing, extra and duplicate receivers. Validate each receiver's credentials, the private setup account and the first blocking rule. Exercise first-user provisioning, last-user removal, activation failure and restoration of the previous users/configuration pair.
- [ ] Extend `tests/unit/test_pending_proxy_setup.bats` and `tests/unit/test_user_removal_safety.bats` for HTTP alone and HTTP plus SOCKS. Add runtime configuration checks to `tests/unit/test_service_modes.bats`. Failure example: selecting HTTPS without SOCKS must not create a 1080 listener or permit an empty HTTP account list.

```bash
bats tests/unit/test_service_modes.bats tests/unit/test_pending_proxy_setup.bats tests/unit/test_proxy_auth_guard.bats tests/unit/test_user_removal_safety.bats
```

Expected evidence includes the exact listener/tag sets for each mode and a successful closed-state transition for a single receiver.

### Task 4. Apply access controls to the right ports

**Depends on Tasks 1–3. Result.** A proxy on 443 receives the same restrictions as a proxy on a custom port.

- [ ] Pass resolved service ports through the installer firewall setup, `lib/orchestrator.sh`, `lib/proxy_security.sh`, `lib/proxy_whitelist.sh`, `lib/ufw_whitelist.sh` and `lib/fail2ban_setup.sh`. Remove unconditional VPN grants from the proxy-only path. Retain source restrictions, authenticated proxy rule ownership, effective SSH access and unrelated rules.
- [ ] Exercise a failed bind after preflight. Before activation, capture the files and rules changed by that operation. Reuse the existing restoration paths. Restore only changes owned by that operation if activation fails. Verify a service that already held the port continues serving.
- [ ] Extend the firewall, source-IP and jail tests. Cover proxy-only 443, custom ports, enabled plaintext ports, a conflicting operator rule and idempotent reapplication. Check the refused source has no alternative broad grant.

```bash
bats tests/unit/test_proxy_firewall.bats tests/unit/test_proxy_fail2ban.bats tests/unit/test_proxy_source_ip.bats tests/unit/test_installer_security_setup.bats
```

Expected evidence includes effective grants and jail port lists matching the selection. Task 7 checks real network behavior.

### Task 5. Preserve endpoints in client and maintenance commands

**Depends on Tasks 1–4. Result.** Issued links match user permissions and survive maintenance.

- [ ] Update `scripts/familytraffic` and `lib/user_management.sh`. Intersect installed services with user permissions for add, show, regenerate and password rotation. Reject unavailable explicit types before mutating users. Exercise HTTPS-only users with no VPN UUID. Verify URI, QR input and client files against a custom port.
- [ ] Update `lib/transport_manager.sh`, `scripts/familytraffic-mtproxy` and `scripts/familytraffic-security` to resolve saved settings before mutation. Reject adding a VLESS transport in proxy-only mode. Preserve selected endpoints during MTProxy regeneration, security reconciliation and ordinary regeneration. Keep bind-mounted file visibility, backup and rollback behavior.
- [ ] Extend legacy fixtures from Task 1 through each affected write entry point. Compare links, accounts, keys, active protocols and restrictions before and after. On ambiguous layouts, verify the operation exits before any write or reload. Allow unaffected read-only commands to continue.

```bash
bats tests/unit/test_service_modes.bats tests/unit/test_proxy_security_migration.bats
bash tests/test_proxy_uri_generation.sh
```

Expected evidence includes the exported HTTPS endpoint on the chosen port and identical settings after repeated regeneration.

### Task 6. Report health and traffic by configured service

**Depends on Tasks 1–3. Result.** A healthy proxy-only host reports HTTPS traffic on 443 and fails its health check when its backend stops.

- [ ] Add a single health-check script to the application image. Wire `docker/familytraffic/Dockerfile` and `docker-compose.yml` to the same entry point. Include its required resolver or resolved inputs in the image. Check each selected public listener and required backend without requiring a real user account. Retain checks for supported older configurations. Update `lib/verification.sh` and `lib/security_tests.sh` wherever they assume fixed ports.
- [ ] Emit a bounded logical listener label from `lib/nginx_stream_generator.sh`. In `monitoring/exporter/internal/journal/parser.go`, prefer the explicit service label on new records. Decode historical numeric records using the old mapping. Add paired records to `parser_test.go` for new HTTPS on 443, legacy VPN on 443 and new HTTPS on a custom port. Reject unknown explicit labels.
- [ ] Exercise both health-check entry points on a disposable deployment. Verify healthy before provisioning, unhealthy after backend loss and healthy after restoration. Check reported service labels after restart.

```bash
go -C monitoring/exporter test ./internal/journal
bats tests/unit/test_service_modes.bats tests/unit/test_traffic_monitoring.bats
```

Expected evidence includes the same health decision from image and Compose and distinct metrics for legacy VPN and new HTTPS on 443.

### Task 7. Verify installations and publish the operator instructions

**Depends on Tasks 1–6. Result.** Every approved outcome has evidence from the relevant installation, client or recovery path.

- [ ] Extend the isolated cases under `tests/security_lab/` and `tests/monitoring/`. Use the reviewed image and local target. Run the actual installer on clean disposable hosts with Docker and UFW for fresh-install evidence. Exercise its existing certificate acquisition and renewal path with a test domain and a trusted test certificate authority. A generated-config lab alone cannot prove installer ordering, issuance or renewal.
- [ ] Cover default VPN, VPN on a custom port, combined mode with SOCKS on/off, and proxy-only on 443 and a free custom port. Include a custom SOCKS port and opt-in plaintext overrides. Use the generated client details to reach the target over each selected protocol before and after restart. Check TLS hostname validation, absence of disabled listeners, and absence of Reality keys in proxy-only mode.
- [ ] Probe before first user, after first user and after last removal. Verify denied source, fail2ban on selected ports and preserved source IP. Compare file hashes and live service on a conflicting upgrade fixture. Exercise certificate renewal, maintenance regeneration, reload failure and the late port collision from Task 4. Record redacted observed results per case.
- [ ] Run focused tests during iteration and the full repository CI check set from `.github/workflows/lint-and-test.yml` once per final stable fingerprint. Include the upstream Xray and Prometheus jobs listed there. These commands cover the main local gates and image-based labs:

```bash
./tests/lint.sh
bats --print-output-on-failure tests/unit/
go -C monitoring/exporter test -race ./...
python3 -m unittest discover -s tests/monitoring -p 'test_*.py'
docker build -f docker/familytraffic/Dockerfile -t familytraffic:service-modes .
bash tests/security_lab/run.sh --image familytraffic:service-modes
FT_TRAFFIC_IMAGE=familytraffic:service-modes bash tests/monitoring/run.sh
```

- [ ] Update `README.md`, `docs/GUIDES.md`, recovery instructions and the relevant deployment wiki guidance. Bind GWT scenarios for the new observable contracts to their executable tests. Retain the last-user scenario ID and check its context before changing its bindings. Record verification in the task ledger and run the plan-backed result check.
- [ ] **Human checkpoint.** Escalate a change to existing client endpoints, authentication or supported upgrade behavior. Use only disposable targets for acceptance. If the required environment is unavailable, record the exact missing cases and keep result verification pending.

Acceptance evidence includes the tested revision and image identity, observed sockets, usable client connections, applied access rules, health transitions, traffic labels and recovery results. Keep credentials out of this record.
