---
chain:
  intent: docs/superpowers/intents/2026-11-26-proxy-public-landing-page-intent.md
  spec: docs/superpowers/specs/2026-11-26-proxy-public-landing-page-design.md
review:
  plan_hash: 5306df5516931dbb
  last_run: 2026-11-27
  phases:
    structure: { status: passed }
    coverage: { status: passed }
    dependencies: { status: passed }
    verifiability: { status: passed }
    consistency: { status: passed }
  findings: []
result_check:
  verdict: OK
  source: plan
  plan_hash: 5306df5516931dbb
  last_run: 2026-11-27
  reviewed: true
  docs_checked: true
---
# Public landing page implementation plan

**Status:** approved

**Goal:** Serve one local page at the approved browser addresses while preserving authenticated forwarding and existing VPN connections.

**Architecture:** Nginx owns TLS and selects the service-domain virtual host on a combined VPN listener. On the HTTPS proxy listener, the existing Xray HTTP parser can terminate a direct local request before outbound dispatch. Both responses use the same HTML source. The host configuration generators and image must agree on the domain and selected ports.

**Stack:** Bash, Python, Nginx stream and HTTP modules, the project's pinned Go/Xray build, Docker, and Bats.

**Spec:** [Approved public landing page design](../specs/2026-11-26-proxy-public-landing-page-design.md). Read the [approved intent](../intents/2026-11-26-proxy-public-landing-page-intent.md) before execution.

## Global constraints

- Keep existing client endpoints, passwords, VPN links and public firewall grants. Port 80 retains the ACME workflow.
- Use local static content. Keep credentials and diagnostics out of the HTML and test evidence.
- Preserve existing ownership, permissions and file bind mounts when updating deployment state. Store backup credentials only in a private fixture or recovery directory.
- Use isolated test networks and disposable deployment files. Changing a live installation requires separate operator authorization.

## Task 1. Prove TLS listener identity at the private HTTP receiver

**Covers:** Shared HTTPS proxy endpoint. TLS and optional plaintext both feed the same private receiver; the public Host header cannot identify its ingress port.

- [ ] Extend the existing isolated harness in `tests/integration/test_service_mode_runtime.sh`. Generate a combined TLS/plaintext fixture and send the same direct request on both listeners. Record only the destination port delivered by the Nginx PROXY connection and the local address reported by Xray's pinned Go connection wrapper. Use a test-only observation in the fixture. Keep the production journal free of visit records.
- [ ] Exercise default and custom HTTPS ports. Include a private connection with missing or unusable listener metadata and verify that it cannot qualify for local service. The decisive comparison is the observed destination against the configured HTTPS port, independently of Host.
- [ ] Confirm the resulting observation against the packaged handler in Task 2. If the real backend cannot distinguish the listeners, stop this implementation path and return to the design decision before changing the authentication path.

Build the local test image from the checkout. Rebuild after image inputs change. Use the same tag for the remaining runtime checks.

```bash
docker build -f docker/familytraffic/Dockerfile -t familytraffic:landing-test .
FT_TEST_IMAGE=familytraffic:landing-test bash tests/integration/test_service_mode_runtime.sh
```

**Pass:** Requests through different public ports yield their respective destination ports at the private side. A fixture without valid HTTPS ingress evidence cannot select the local response.

## Task 2. Serve the fixed page on the HTTPS proxy endpoint

**Depends on Task 1. Covers:** Browser GET/HEAD, proxy authentication, private asset packaging and journal behavior.

- [ ] Add one HTML file at `docker/familytraffic/xray/landing.html`. Keep its CSS inline and omit external resources. Use this resource directory because the focused upstream-test builder already mounts it. In `docker/familytraffic/xray/build.sh`, copy it into the patched Go package before compilation. In `docker/familytraffic/Dockerfile`, copy the same source to a read-only file outside the ACME webroot for Task 3.
- [ ] Add request-table tests to the pinned HTTP receiver via a dedicated `docker/familytraffic/xray/landing-page.patch`. Apply it after `auth-journal.patch` in the existing build and test paths. Run the tests before introducing the local response and observe the failure for a direct browse request.
- [ ] In the existing parsed-request loop, consider a local response only for a managed proxy mode, the HTTP proxy inbound, the verified HTTPS ingress port, the configured authority, and origin-form GET or HEAD. Match DNS names case-insensitively. Treat an omitted port as 443. Serve the embedded asset at the root, including a root query; return a local 404 for other eligible paths. Return after writing the local response. Use the existing account check and dispatch path for proxy requests.
- [ ] Cover GET, HEAD, a root query, an unknown path, wrong authority or port, missing ingress evidence, and plaintext. Test CONNECT and absolute-form requests with missing, wrong and valid credentials. Include an absolute-form request addressed to the service domain. Assert zero outbound calls for local responses, the correct HEAD representation length and empty body, and no new auth-journal entry from browsing.

```bash
bash docker/familytraffic/xray/test.sh focused
docker build -f docker/familytraffic/Dockerfile -t familytraffic:landing-test .
FT_TEST_IMAGE=familytraffic:landing-test bash tests/integration/test_service_mode_runtime.sh
```

**Pass:** Browsing over TLS returns 200 with the expected document. Refused forwarding returns 407. Normal authenticated forwarding and existing journal behavior pass the focused checks. The packaged handler makes the same TLS/plaintext distinction as Task 1.

## Task 3. Route the combined-mode browser address and protect existing names

**Depends on Task 2 for the packaged asset. Covers:** The bare service domain on the shared VPN port, custom port assignments, VPN-only installations and conflict refusal.

- [ ] Extend `tests/unit/test_service_modes.bats` with generator fixtures for proxy-only, combined, VPN-only, custom ports and enabled Tier 2 names. Include a service-domain collision with an active Reality name other than the configured destination, and a collision with an enabled transport name.
- [ ] In `lib/nginx_stream_generator.sh`, render one exact service-domain entry in the existing combined-mode SNI map. Route it to the private Unix-socket TLS virtual host. Serve the Task 2 file for the configured authority with the existing domain certificate. Match the local GET/HEAD root and 404 behavior. Keep other server names, the default Reality route, disabled modes and ACME routing intact.
- [ ] Pass effective names from the staged or installed Xray configuration and enabled transport settings through `lib/orchestrator.sh` and `lib/transport_manager.sh`. Compare normalized DNS names before publishing changes. On conflict, return an error identifying the name. Use the same check for both installation and regeneration.
- [ ] Exercise the target image with the generated configuration. Compare both browser response bodies, verify their certificates and list public sockets. With custom settings where FamilyTraffic owns no port 443, assert the generated configuration adds no listener there.

```bash
bats tests/unit/test_service_modes.bats
FT_TEST_IMAGE=familytraffic:landing-test bash tests/integration/test_service_mode_runtime.sh
```

**Pass:** Combined mode serves identical bytes on 443 and the selected HTTPS proxy port. Regeneration preserves Tier 2 and Reality routing. Both collision fixtures fail before activation. VPN-only and ACME checks retain their previous results.

## Task 4. Activate matched settings and recover a failed update

**Depends on Tasks 2 and 3. Covers:** Fresh installation, supported legacy settings, container environment, staging, reload and rollback.

- [ ] In `tests/unit/test_installer_runtime.bats` and `tests/unit/test_service_modes.bats`, exercise an explicit deployment, an unambiguous legacy deployment, an ambiguous legacy deployment, and a rejected reload. Snapshot affected configuration, permissions and user data in an isolated root before each attempt.
- [ ] Use `load_service_settings` from `lib/service_modes.sh` and the existing reader in `lib/service_settings.py`. Pass the same effective service mode, domain and HTTPS port to generation and container startup. Stage any required legacy environment update while preserving unrelated keys. A shell export alone does not update an existing container's environment; recreate the service with the matched target image when the container settings change.
- [ ] In the installer and transport update paths, perform name checks before editing active Xray, Nginx, transport or environment state. Stage and validate the complete candidate against the target image, Xray configuration, asset and certificate mounts. Use the existing deployment's inode-preserving writes for live file mounts and its applicable recovery helpers.
- [ ] If reload or recreation fails, restore the affected files and previous runtime settings and image, then verify the previous service through its normal client endpoints. Check an unchanged rerun and a retry after recovery. On a fresh installation, ensure a rejected candidate never becomes active.

```bash
bats tests/unit/test_installer_runtime.bats tests/unit/test_service_modes.bats tests/unit/test_proxy_security_migration.bats
FT_TEST_IMAGE=familytraffic:landing-test bash tests/integration/test_service_mode_runtime.sh
```

**Pass:** The generator and container agree on the same settings. An ambiguous legacy fixture leaves the active state untouched. A failed reload preserves file contents, relevant modes, mount visibility, user credentials and working connections. A subsequent valid attempt succeeds.

## Task 5. Verify the approved outcomes and document operation

**Depends on Tasks 1–4. Covers:** The specification's complete verification matrix and release criteria.

- [ ] Extend `tests/integration/test_service_mode_runtime.sh` to make real client requests in an isolated network with a controlled HTTP and HTTPS destination. Record its request counter around each attempt. Run before first-user provisioning and with missing, wrong and valid proxy credentials. Check both direct browser methods, both combined addresses, custom HTTPS ports, plain HTTP and SOCKS where enabled. Check certificate hostname and trust without disabling verification.
- [ ] Transfer a known payload through an existing VLESS link before enabling the page, after enabling it and after restart. Recheck an enabled Tier 2 transport and its route, the public listener inventory, ACME challenge handling, and the VPN-only fixture. Record body digests, counts, status codes and the image identity. Redact client links and secrets.
- [ ] Update `docs/GUIDES.md` with the browser addresses, authentication behavior, domain-conflict message and upgrade requirements. Run the packaged suite from CI alongside the existing isolated checks. In `VERSION`, select the release bump against the then-current test branch so the image and host generators ship together.
- [ ] Run the focused checks during iteration. Once the code, image inputs and fixture are stable, run the final suites once for that fingerprint and record exit statuses and skips. Reconcile the observed results against the approved intent before branch finishing.

```bash
./tests/lint.sh
bats --print-output-on-failure tests/unit/
bash docker/familytraffic/xray/test.sh all
FT_TEST_IMAGE=familytraffic:landing-test bash tests/integration/test_service_mode_runtime.sh
```

**Pass:** Both browser entry points return identical content, and HEAD returns no body. The controlled origin sees zero refused requests and receives the authorized requests. VPN traffic still passes after restart. The recovery check and retained service-mode regressions pass.

## Execution and checkpoints

Recommended execution is inline with `superpowers:executing-plans`. The port observation determines the handler boundary; the asset, activation and runtime acceptance then share one image. Commit each verified unit on the feature branch. The above checks are planned evidence.

**Human checkpoint:** Return to the operator if the approved behavior would require a new public port, new credentials, a changed VPN link, or a change to the proxy authentication contract. A live deployment requires separate authorization.
