---
chain:
  intent: docs/superpowers/intents/2026-11-26-installer-service-modes-intent.md
review:
  spec_hash: 8c5eeb111e9f132a
  last_run: 2026-11-26
  phases:
    structure: { status: passed }
    coverage: { status: passed }
    clarity: { status: passed }
    consistency: { status: passed }
  findings: []
---
# Installer service modes

**Status:** approved

## Deployment settings

The operator chooses the deployment mode once during fresh installation. The existing installation file `/opt/familytraffic/.env` owns that choice. A separate settings file would require coordinating two writes during installation and recovery. Inferring the mode on each run from nginx would mistake unused listeners in older templates for enabled services.

Store `FT_SERVICE_MODE` as `vpn`, `proxy` or `both`. Store the selected decimal public ports in `FT_VLESS_PUBLIC_PORT`, `FT_HTTPS_PROXY_PORT` and `FT_SOCKS_TLS_PORT`. An empty SOCKS port disables SOCKS. Leave ports for disabled services empty. Keep the existing internal `VLESS_PORT` meaning. Preserve existing TLS and plaintext flags and derive overlapping legacy flags from the same selection.

Use one resolver for installer and maintenance scripts. Parse the relevant keys as data. On fresh installation, resolve the answers in memory before generating files. After installation, read the persisted selection. Validate it as a unit. Reject conflicting duplicate fields, missing required ports and inconsistent mode/port combinations. A partial new-format configuration must surface an error. Preserve unrelated settings and file protections when saving.

## Compatibility with installed systems

| Observed state | Required behavior |
|---|---|
| Complete new settings | Render the selected mode and ports on every regeneration. |
| Legacy layout with no new fields | Use legacy public proxy and TLS flags, managed Xray receivers and matching nginx routes to recover existing service endpoints. Preserve the effective scheme, ports, accounts, keys and restrictions. Leave the files intact during discovery. |
| Known VPN-only legacy template with unused proxy listeners | Recognize the managed template and absence of active public proxy receivers. Keep VPN-only access and existing VPN links. |
| Unambiguous operator-selected ports | Preserve the port-to-service mapping when regeneration can reproduce the configuration and its access restrictions. |
| Ambiguous routing, conflicting settings or unrecognized access restrictions | Before an operation would rewrite affected state, report the conflicting service, file and field. Preserve files, live processes and firewall rules. Keep independent read-only operations available. |

A fresh installation must still respect the existing saved-user guard. Regeneration and upgrades must never rerun the mode-selection wizard on an existing host. A security reconciliation may still reject an unsafe configuration under its existing checks.

## Installation and validation

1. Select the mode before asking for ports. Keep VPN-only as the default. In proxy modes, offer HTTPS and separately offer SOCKS over TLS. Leave SOCKS disabled unless selected.
2. Prompt for each enabled public port. Retain explicit plaintext selection and prompt for each additional enabled plaintext endpoint using its existing default (HTTP 8119, SOCKS 1081 for the additional listeners). Store selected additional ports in `FT_HTTP_PLAIN_PORT` and `FT_SOCKS_PLAIN_PORT`. Leave them empty when disabled. Keep existing plaintext-only installations on their recorded scheme and effective ports. A plaintext endpoint requires its corresponding selected proxy protocol.
3. Validate decimal TCP ports in the range 1–65535. Detect duplicates, host socket conflicts across applicable address families and overlaps with management, ACME, internal backends and selected optional services. Preserve the existing SSH port. Include late optional service selections in conflict checks before they claim a port.
4. Show the effective services, transport security and public ports. Complete validation before applying service or firewall changes. If a port becomes occupied after validation, report the failed bind and keep existing services and access rules intact through the operation's recovery path.
5. Collect Reality parameters and generate keys only for VPN modes. In proxy modes, retain DNS validation, certificate acquisition, renewal and TLS termination. Allow the existing HTTP-01 challenge on its required port. The browser landing page remains a stage-two proposal.

## Runtime and maintenance

| Consumer | Behavior |
|---|---|
| Xray and nginx | Create only selected VPN/proxy receivers and public listeners. In proxy-only mode terminate TLS on the chosen HTTPS port and forward to the authenticated HTTP receiver on loopback. Keep PROXY protocol and real-client address handling. In VPN modes route the public VPN port to Reality and existing enabled Tier 2 transports. |
| Access control | Derive UFW, allowlists and fail2ban port sets from the active protocols, including explicit plaintext endpoints. Keep SSH management access and operator rules. On proxy-only 443 apply the proxy restrictions, without an additional broad VPN grant. |
| User commands and exports | Offer only supported connection types. Reject explicit requests for disabled types before changing user data. For existing users, export the intersection of deployment services and user permissions. Use the selected address, scheme and port for links, QR codes and client files. |
| Empty proxy account set | Validate the exact enabled receiver tags, including the HTTPS-only case. Apply the existing private setup credential and first blocking route to all enabled proxy receivers. Unlock only after successful provisioning. Restore the lock before committing last-user deletion. Preserve rollback on activation or persistence failure. |
| Regeneration | Installer, transport manager, MTProxy tooling and security reconciliation resolve the same saved deployment before modifying a generated file. Reject VPN-only operations, such as adding a VLESS transport, on a proxy-only host before writing state. Preserve bind-mounted file visibility and existing reload/recovery semantics. |
| Health checks | Compose and image health checks verify the selected public listeners and their required internal backends. A closed proxy awaiting its first user can be healthy. A missing selected backend must fail the check. |
| Monitoring | Emit the logical service label with each new nginx traffic event from the configured listener mapping. Export existing bounded service labels. Retain numeric-port decoding for historical records from the legacy format. |

## Verification and recovery

Use disposable installations for network and firewall checks. Compare the actual public sockets, emitted client details, a real authorized connection and container health before and after restart. Verify that a disabled service has no receiver, public listener, managed access grant or exported connection detail.

| Case | Required evidence |
|---|---|
| Default VPN-only and combined | Connect over VLESS on the advertised port. In combined mode also use the exported HTTPS proxy and exercise SOCKS both enabled and disabled. In VPN-only mode verify that proxy endpoints are absent. |
| Proxy-only on 443 and a custom port | Run with SOCKS disabled. Verify absence of Reality keys and listeners, successful TLS certificate validation with the exported hostname, authorized proxy forwarding, correct traffic label and rejection of unauthorized forwarding. Repeat with SOCKS enabled and a custom SOCKS port. |
| User lifecycle and access restrictions | Verify closed access with zero users, normal first-user access, rejection from a restricted source, recorded client address, fail2ban protection on the configured port, and closed access after last-user removal. Force activation failure and verify saved accounts and previous access survive. |
| Port selection and regeneration | Exercise invalid, duplicate, occupied and reserved ports before changes. Exercise a custom VPN port, opt-in plaintext overrides, certificate renewal, regenerating existing client files and an applicable maintenance command that regenerates nginx. Check repeat runs preserve the chosen endpoints. |
| Legacy upgrade and ambiguous input | Compare links, credentials, enabled protocols, access restrictions and real connectivity using representative managed VPN, combined and explicit plaintext fixtures. For contradictory evidence, verify the command names the conflict and file hashes, live service and firewall rules remain unchanged. |
| Service loss | Stop a selected backend on an isolated host. Verify the health check detects the failure and recovers when service resumes. |

## Acceptance (from intent)

The installer asks for the service mode before it asks for public ports. Enter accepts the displayed default.

| Mode | Public VLESS port | Public HTTPS proxy port | SOCKS5 over TLS |
|---|---:|---:|---|
| VPN only (default) | 443 | Disabled | Disabled |
| Proxy only | Disabled | 443 | Optional, default port 1080 when selected |
| VPN and proxy | 443 | 8118 | Optional, default port 1080 when selected |

- Operators can override the public port of each selected service. The installer skips questions for disabled services.
- In proxy-only mode, the operator supplies the TLS certificate details and skips Reality setup. The host has no VLESS listener or generated Reality keys.
- An invalid, occupied, reserved or duplicate port produces an actionable error before the installer applies service or firewall changes.
- Client connection details identify only available services and use the selected external ports. Authorized clients can connect with those details after a restart.

- Done when: all three fresh-install modes expose the selected services and accept authorized clients on their advertised ports after restart.
- Done when: proxy-only installations pass those checks on port 443 and on a custom port, reject unauthorized forwarding and have no VLESS listener.
- Done when: each health metric has verification evidence, including compatibility with an existing deployment.
