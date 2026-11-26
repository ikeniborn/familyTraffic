---
workflow:
  route: chain
  continuation: full
review:
  intent_hash: 72be5427e36607e6
  last_run: 2026-11-26
  phases:
    structure: { status: passed }
    completeness: { status: passed }
    clarity: { status: passed }
    consistency: { status: passed }
    alignment: { status: passed }
  findings: []
---
# Intent: Installer service modes

**Date:** 2026-11-26
**Status:** approved

## Objective

Let an operator deploy an authenticated HTTPS proxy on a fresh host without provisioning VLESS. Keep VPN-only and combined installations available.

## Desired Outcomes

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

## Health Metrics

- Each tested mode reaches container health status `healthy` after installation and restart.
- The number of listeners for disabled VPN or proxy services is zero. Firewall setup grants access only to the selected service ports and required infrastructure.
- Zero unauthenticated proxy requests relay traffic, including before the first proxy user exists and after the last one is removed.
- With monitoring enabled, a connection to the HTTPS proxy on port 443 is counted as proxy traffic. The same classification holds on a custom port.
- Existing deployments retain their enabled services, public ports, credentials and working client links after an upgrade or configuration regeneration.

## Strategic Context

- Interacts with: installer prompts, Xray, nginx, certificate issuance and renewal, UFW, fail2ban, user management, client exports, container health checks and traffic monitoring.
- Priority trade-off: preserve access controls and existing client connectivity before reducing installation effort.

## Constraints

### Steering

- Offer port defaults for the selected mode. Show the selected services and public ports before applying them.
- Reuse the existing deployment and user-management workflows.

### Hard

- Apply mode selection to fresh installations. Treat mode switching on an installed server as separate work.
- Preserve SSH access, proxy authentication, source-address restrictions and certificate renewal for the selected services.
- Keep plaintext proxy access opt-in. Preserve existing installations with an explicit plaintext configuration.
- Keep the proposed public landing page and browser redirect outside stage one.

## Autonomy Zones

- Full autonomy: choose reversible implementation details and focused test fixtures within the accepted scope.
- Guarded: change generated listeners, access rules, health checks and client exports with corresponding verification.
- Proposal-first: obtain approval for a change to the default port matrix, upgrade behavior or public authentication contract.
- No autonomy: deployment to a live host or destructive changes to existing users, keys or firewall state require explicit operator authorization.

## Stop Rules

- Halt if a selected port conflicts with another listener or a required internal service. Report the conflict before applying changes.
- Escalate if compatibility with a supported existing deployment requires changing a client endpoint or weakening access controls.
- Done when: all three fresh-install modes expose the selected services and accept authorized clients on their advertised ports after restart.
- Done when: proxy-only installations pass those checks on port 443 and on a custom port, reject unauthorized forwarding and have no VLESS listener.
- Done when: each health metric has verification evidence, including compatibility with an existing deployment.
