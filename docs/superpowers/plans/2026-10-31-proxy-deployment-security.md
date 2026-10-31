---
review:
  plan_hash: 82ee21c6ff6126b1
  last_run: 2026-10-31
  phases:
    structure: { status: passed }
    coverage: { status: passed }
    dependencies: { status: passed }
    verifiability: { status: passed }
    consistency: { status: passed }
  findings: []
chain:
  intent: docs/superpowers/intents/2026-10-31-proxy-deployment-security-intent.md
  spec: docs/superpowers/specs/2026-10-31-proxy-deployment-security-design.md
---
# FamilyTraffic Proxy Deployment Security Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Follow the project's delegation and approval rules.

**Status:** approved
**Spec:** ../specs/2026-10-31-proxy-deployment-security-design.md
**Intent:** ../intents/2026-10-31-proxy-deployment-security-intent.md

**Goal:** Preserve proxy availability through deployment and enforce auditable IP-based bans for actual credential failures.

**Architecture:** nginx forwards source IPs to loopback Xray receivers. A narrow pinned-Xray patch writes a dedicated authentication journal. Host reconciliation applies compatible configuration, firewall rules, and a verified fail2ban jail as one migration.

**Tech Stack:** Bash, BATS, jq, nginx stream, Xray/Go, Docker Compose, UFW, fail2ban, Python standard-library test harness.

## Global Constraints
- Build Xray from commit 98a72b6fb49bcc403c4cae1ff529b9def43e6ad8, version v24.11.30.
- Use maxretry=5, findtime=600, bantime=3600; exclude SSH and Reality from proxy bans.
- Keep 10800 and 18118 bound to 127.0.0.1. Public clients cannot supply trusted source metadata.
- Preserve authentication, TLS verification, users, routing, certificates, and volumes.
- Do not whitelist the observed client IP. Dynamic addresses require no configuration edits.
- A public-IP ban also affects other clients sharing that NAT; do not claim account-level isolation.
- Do not build application images on the server or mutate shared-host firewall during automated tests.
- Use branch dev-proxy-deployment-security and PR target master.
- Run full suites once per final unchanged state. Preserve command, scope, exit status, and fingerprint.
- HUMAN CHECKPOINT: obtain approval of this checked plan before implementation, and separate approval of the concrete rollout before changing the host's protection mechanism.

## Coverage, ownership, and dependency order
| Task | Requirement | Deliverable | Dependencies |
|---|---|---|---|
| FT1 | R1, R7 | One no-TLS resolution contract and regression tests | None |
| FT2 | R4, R5 | Patched Xray with dedicated journal and image capability | None |
| FT3 | R3, R4 | Compatible nginx/Xray source-IP configuration | FT1, FT2 |
| FT4 | R2, R5 | Idempotent UFW and fail2ban host policy | FT2, FT3 |
| FT5 | R1-R5, R7 | Transactional migration/check entry point | FT1-FT4 |
| FT6 | R1-R5, R7 | Isolated security and rollback acceptance suite | FT1-FT5 |
| FT7 | R1-R7 | Final evidence and separate PR delivery | FT6 and Budget acceptance evidence |

FamilyBudget implementation is owned by its companion plan in the FamilyBudget worktree. Do not edit that repository from an FT task. Its local-only publication is independent and can be reviewed separately. No task marks the combined intent complete without both repositories' evidence. Run FT7 and FB4 only after FT6 and FB3 acceptance artifacts exist; neither final review depends on the other final review verdict. The parent aggregates both local reconciliations before closing the shared intent.

## FT1. Preserve explicit no-TLS selection
**Files:** modify `lib/orchestrator.sh`, `lib/nginx_stream_generator.sh`, `lib/transport_manager.sh`, `scripts/familytraffic`, `scripts/familytraffic-mtproxy`; create `lib/proxy_security.sh`, `tests/unit/test_proxy_state.bats`.

**Interface:** `resolve_proxy_notls CURRENT SAVED_FILE` writes exactly true or false and returns 0. CURRENT is empty, true, or false; invalid nonempty values return 1. A present explicit value wins. Otherwise read the exact persisted PROXY_NOTLS_ENABLED assignment without sourcing shell text; absent state means false. Malformed/duplicate conflicting assignments return 1.

- [ ] Add BATS cases for no saved file + true, explicit false + saved true, absent selection + saved true, absent/absent, and malformed stored input.

```bash
@test "first install honors explicit no-TLS without saved state" {
    source "$PROJECT_ROOT/lib/proxy_security.sh"
    run resolve_proxy_notls true "$BATS_TEST_TMPDIR/missing-state"
    [ "$status" -eq 0 ]
    [ "$output" = true ]
}
```

- [ ] Run the focused test and record failure before adding the resolver.

```bash
bats tests/unit/test_proxy_state.bats
```

- [ ] Implement the resolver and wire all generation paths to the resolved boolean. Keep explicit false distinguishable from an unset choice. Generate consistent nginx, exports, firewall selection, and jail selection. Do not reset existing users or regenerate unrelated transport choices.
- [ ] Add integration-level generator assertions for listen 1081/8119 presence/absence and byte-preserved unrelated transport blocks. Verify existing bind-mounted writes preserve inode where used.
- [ ] Run syntax and focused tests; expect exit 0 and both first-install and repeat-generation cases passing.

```bash
bash -n lib/proxy_security.sh lib/orchestrator.sh lib/nginx_stream_generator.sh lib/transport_manager.sh scripts/familytraffic scripts/familytraffic-mtproxy
bats tests/unit/test_proxy_state.bats
```

- [ ] Review the exact diff and commit `fix: preserve proxy mode across configuration generation`.

## FT2. Build the minimal authenticated-failure journal patch
**Files:** modify `docker/familytraffic/Dockerfile`, `.github/workflows/lint-and-test.yml`, `.github/workflows/build-and-push.yml`; create `docker/familytraffic/xray/auth-journal.patch`, `docker/familytraffic/xray/build.sh`, `docker/familytraffic/xray/test.sh`. The patch adds upstream Go tests beside its changed HTTP/SOCKS code and a small `common/ftauth` package.

**Interfaces:** upstream package `ftauth.Record(protocol string, source net.Addr) error` accepts only http/socks and numeric connection addresses. Production path is fixed `/var/log/xray/auth.log`. An internal writer accepts path/time for unit tests. SOCKS adds `ErrInvalidCredentials`, tested with error identity through its existing wrapper. The image contains `/etc/familytraffic/auth-journal-capability` with exactly `ft-auth-journal-v1`.

- [ ] Add Go tests to the patch for IPv4/IPv6 canonicalization, no port/credential output, timestamp format, unknown protocol rejection, concurrent complete lines, permission errors, rename rotation, and HTTP challenge versus wrong-password behavior.

```go
func TestRejectUntrustedProtocol(t *testing.T) {
    err := Record("http\nforged", &net.TCPAddr{IP: net.ParseIP("192.0.2.10"), Port: 1234})
    if err == nil { t.Fatal("expected rejected protocol") }
}
```

- [ ] Write `test.sh` to fetch the exact upstream commit into a temporary directory, verify HEAD, apply the test-bearing patch, and run the tests. Record initial failures before the event implementation is included. Do not fetch a moving branch.
- [ ] Implement one dedicated append/create/write/close per event, file mode 0600, bounded single-line UTC format. Return write errors to a credential-free protection-error log. Emit only on parsed credential mismatch. Preserve protocol responses and routing.
- [ ] Use a pinned Go builder compatible with the pinned upstream module. Record the exact builder digest in the Dockerfile. Verify patch application strictly; prohibit an unpatched fallback. Build the existing runtime image with the patched binary and capability marker.
- [ ] Run focused Go tests and the complete upstream suite in the isolated builder. `test.sh focused` and `test.sh all` are created by this task; nonzero subprocess status propagates.

```bash
bash docker/familytraffic/xray/test.sh focused
bash docker/familytraffic/xray/test.sh all
```

- [ ] Extend CI path triggers to the Dockerfile and patch tree. Add build-and-test jobs for PRs to master and test without publishing or deployment. Keep existing publication triggers; do not assume a master PR triggers the current test-only release job.
- [ ] Build locally/CI from repository-root context, then inspect the marker and run the patched binary's configuration check. No server build.

```bash
docker build -f docker/familytraffic/Dockerfile -t familytraffic:proxy-security .
```

- [ ] Commit `feat: add credential-safe Xray authentication events` after tests and image checks pass.

## FT3. Forward trusted source addresses and preserve authentication
**Files:** modify `lib/nginx_stream_generator.sh`, `lib/orchestrator.sh`, `lib/proxy_security.sh`, `lib/xray_routing_manager.sh`, `lib/user_management.sh`, `lib/verification.sh`; create `tests/unit/test_proxy_source_ip.bats`, `tests/unit/test_proxy_auth_guard.bats`.

**Interfaces:** `validate_proxy_auth_config CONFIG_JSON` returns 0 only when enabled public proxy inbounds have nonempty accounts and SOCKS password authentication. `stage_proxy_security_config CURRENT_JSON OUTPUT_JSON` updates only proxy loopback sockets, PROXY acceptance, and the obsolete generated loopback-source condition. It does not rebuild user routes from defaults.

- [ ] Add failing tests that assert four outgoing nginx PROXY directives, no incoming public PROXY listener, unchanged Reality stream, and private Xray receiver addresses.

```bash
@test "empty HTTP accounts fail public preflight" {
    source "$PROJECT_ROOT/lib/proxy_security.sh"
    printf '%s
' '{"inbounds":[{"tag":"http-proxy","protocol":"http","settings":{"accounts":[]}}]}' > "$BATS_TEST_TMPDIR/config.json"
    run validate_proxy_auth_config "$BATS_TEST_TMPDIR/config.json"
    [ "$status" -ne 0 ]
}
```

- [ ] Add fixtures containing per-user external proxies, existing Tier 2 transports, and the generated loopback-source rule. Assert unrelated JSON subtrees and route ordering remain unchanged.
- [ ] Implement the staged update using jq and temporary files. Check empty-account and failed synchronization paths before listener activation. Do not downgrade a failed account sync to a warning.
- [ ] Update routing only for the recognized generated inbound rule. If a custom source restriction is ambiguous, fail with a diagnostic instead of deleting it.
- [ ] Run focused checks and validate staged configs with the built image's nginx and Xray binaries. Fixture certificates belong only to the lab.

```bash
bats tests/unit/test_proxy_source_ip.bats tests/unit/test_proxy_auth_guard.bats
bash -n lib/proxy_security.sh lib/nginx_stream_generator.sh lib/orchestrator.sh lib/verification.sh
```

- [ ] Commit `fix: preserve client addresses across proxy forwarding`.

## FT4. Reconcile UFW and effective fail2ban monitoring
**Files:** modify `lib/orchestrator.sh`, `lib/fail2ban_setup.sh`, `lib/proxy_security.sh`; create `tests/unit/test_proxy_firewall.bats`, `tests/unit/test_proxy_fail2ban.bats`, `tests/fixtures/proxy-auth-positive.log`, `tests/fixtures/proxy-auth-negative.log`.

**Interfaces:** `reconcile_proxy_firewall NOTLS` owns only the recognized global proxy rules. `configure_proxy_auth_jail PORTS` writes the single managed jail and strict filter. `verify_proxy_auth_jail PORTS` validates live file monitoring, settings, and action port set. Every failure returns nonzero.

- [ ] Add stateful UFW mocks for absent, managed LIMIT, managed ALLOW, and operator-restricted rules. Assert a second run is unchanged and a custom restriction is never broadened.

```bash
@test "custom source restriction is not replaced by global allow" {
    source "$PROJECT_ROOT/lib/proxy_security.sh"
    ufw() { printf '%s
' '1080/tcp ALLOW IN 192.0.2.10'; }
    run reconcile_proxy_firewall false
    [ "$status" -ne 0 ]
}
```

- [ ] Capture positive journal fixtures from FT2. Add negatives for challenge responses, successful auth, general-log text, forged headers, embedded newlines, nonnumeric sources, malformed dates, and loopback exclusion. Do not use real credentials.
- [ ] Implement exact managed-rule reconciliation with the runtime-tested UFW allow replacement. Create `familytraffic-proxy-auth` with polling, usedns=no, configured thresholds and exact enabled ports. Preserve SSH and custom jails.
- [ ] Back up and disable only known project-owned legacy jails. Reject ambiguous customizations and missing writable journal. Configure rotation for auth.log with secure creation permissions; rename rotation must not truncate concurrent writes.
- [ ] Run BATS and `fail2ban-regex` in the isolated node from FT6. Positive fixture count must equal emitted credential failures; negative fixture match count must be zero. Verify `fail2ban-client -t` and live jail logpath/backend.

```bash
bats tests/unit/test_proxy_firewall.bats tests/unit/test_proxy_fail2ban.bats
```

- [ ] Commit `fix: reconcile proxy firewall and fail2ban policy`.

## FT5. Integrate transactional migration and verification
**Files:** create `scripts/familytraffic-security`, `tests/unit/test_proxy_security_migration.bats`; modify `install.sh`, `scripts/familytraffic`, `lib/orchestrator.sh`, `lib/proxy_security.sh`, `lib/verification.sh`, `docs/GUIDES.md`, `docs/MIGRATION.md`, `docs/SECURITY.md`.

**CLI contract:** `familytraffic-security check` is read-only and exits nonzero for ineffective protection. `familytraffic-security reconcile --image IMAGE` validates an existing prebuilt image, backs up owned state, applies the compatible pair, reconciles host policy, and verifies. IMAGE must be a locally available immutable image identity; do not pull/build implicitly. Root is required for reconciliation. Installation can call internal functions before initial public activation.

- [ ] Add mocked command traces proving validation precedes mutation, configuration/image change is coordinated, existing user files remain byte-identical, and failure at each boundary triggers rollback. Assert check mode invokes no mutation command.

```bash
@test "check mode cannot mutate host policy" {
    run bash "$PROJECT_ROOT/scripts/familytraffic-security" check
    [ "$status" -ne 0 ]
    # The fixture PATH records commands; inspect its trace for forbidden mutations.
    ! grep -Eq 'ufw (allow|delete|reload)|compose (up|down)|nginx -s' "$BATS_TEST_TMPDIR/commands.log"
}
```

- [ ] Implement preflight: image marker, staged binary validation, nonempty authentication, saved-user integrity, writable journal, and owned-policy detection. Backups use restrictive permissions and never print secret config contents.
- [ ] Apply the staged pair and image during a controlled restart. Verify traffic, then UFW, then jail. Roll back pair/image and owned policies on any failure; report degraded old protection explicitly. Never restore a whole host ruleset over unrelated concurrent rules.
- [ ] Wire fresh install, start/update guidance, and supported deployment paths to reconciliation/check. Existing `update` currently prints manual guidance; make its documented recipe invoke the scoped entry point. Do not invoke full installer on an existing deployment.
- [ ] Update installation success output to report actual monitoring state. Document required image/config pairing, NAT behavior, dynamic IP, log retention, unban, rollback, and no fixed allowlist.
- [ ] Run focused migration and prior tests; expect deterministic rollback and unchanged user/route fixtures.

```bash
bats tests/unit/test_proxy_security_migration.bats tests/unit/test_proxy_state.bats tests/unit/test_proxy_auth_guard.bats
bash -n scripts/familytraffic-security install.sh scripts/familytraffic lib/verification.sh
```

- [ ] Commit `feat: reconcile proxy security during installation and deployment`.

## FT6. Prove the security contract in an isolated network
**Files:** create `tests/security_lab/compose.yml`, `tests/security_lab/node.Dockerfile`, `tests/security_lab/run.sh`, `tests/security_lab/test_proxy_security.py`; modify `.github/workflows/lint-and-test.yml` and `tests/integration/README_ENCRYPTION_TESTS.md`.

**Harness contract:** `run.sh --image IMAGE` creates a uniquely named disposable Compose lab, never a host-network container. A Debian firewall/fail2ban node has NET_ADMIN only in its own network namespace. The production image shares that node namespace. The lab mounts temporary configs/logs and test certificates; client containers have distinct source IPs on the isolated bridge. A controlled HTTPS target uses the lab CA. Exit 0 requires every case; cleanup removes only lab resources. No SSH or production credentials are accepted.

- [ ] Add actual client probes using Python sockets/ssl for HTTP/SOCKS and a temporary Xray client for VLESS/TLS-SOCKS. Every protocol must authenticate and fetch the controlled target; TLS verification uses the fixture CA.
- [ ] Create test cases for all spec section 8 rows: 8-connect bursts, wrong credentials, challenge, malformed input, public address spoofing, log injection, five-failure ban, another client's success, IP change, manual unban, expiry, rotation, jail restart, UFW reload, empty accounts, image mismatch, and migration rollback. Use a short explicit test-only bantime only for expiry timing; separately assert the production 3600 value.

```python
def test_offender_does_not_block_other_ip(self):
    lab = self.lab
    for _ in range(5):
        lab.http_request("offender", password="wrong", expected_status=407)
    lab.wait_banned("offender", timeout=15)
    lab.assert_proxy_connection_blocked("offender")
    lab.http_request("valid", password=lab.valid_password, expected_status=200)
```

The unittest `lab` fixture is implemented in `test_proxy_security.py`; it invokes client containers, bounds waits, records redacted artifacts, and destroys only its own resources. It must not infer success from service process state alone.

- [ ] Verify five failures aggregate across enabled proxy ports and only proxy ports are banned. Test a valid client after source-address change, not a permanent allowlist.
- [ ] Run the harness against old and new behavior where compatible; record original failure evidence and final results. Include synthetic rollback and migration failures without touching the shared server.

```bash
bash tests/security_lab/run.sh --image familytraffic:proxy-security
```

- [ ] Add the lab as a PR check for master/test. Require Linux network-namespace support; report a blocked required check if unavailable rather than silently skip.
- [ ] Commit `test: verify proxy security and migration end to end`.

## FT7. Final review, evidence, and delivery
- [ ] Run syntax and focused checks first. After the final relevant input changes, run the full repository unit suite, lint gate, full patched upstream Go suite, and complete security lab once. Reuse unchanged evidence.

```bash
bash tests/lint.sh
bats --print-output-on-failure tests/unit/
bats --count tests/integration/
bats --count tests/performance/
bash docker/familytraffic/xray/test.sh all
bash tests/security_lab/run.sh --image familytraffic:proxy-security
```

- [ ] Review all changed paths against R1-R7. Obtain a separate final integration review of the coordinated protocol/config migration. Keep failures and unavailable required infrastructure visible.
- [ ] Run check-chain result against this plan and reconcile O1-O7 using the companion FB3 acceptance evidence. Record actual command evidence and fingerprints, not the expected outputs in this plan.
- [ ] Prepare the FamilyTraffic PR to master, with the Budget PR linked. Do not imply the current test-only release pipeline published the master implementation. Include a concrete manual CI publication/rollout recipe and rollback image IDs for approval.
- [ ] HUMAN CHECKPOINT: request approval of the new host-protection rollout only after the PR result and lab evidence are reviewable. Do not run authentication bans from the active SSH client against ikeniborndev.
- [ ] Keep lifecycle completion-pending while wiki replay/lint is unavailable. No implementation or test success is claimed by this plan.
