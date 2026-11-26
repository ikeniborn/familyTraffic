---
workflow:
  route: chain
  continuation: full
review:
  intent_hash: a03feeb8ac83b5f4
  last_run: 2026-11-26
  phases:
    structure: { status: passed }
    completeness: { status: passed }
    clarity: { status: passed }
    consistency: { status: passed }
    alignment: { status: passed }
  findings: []
---
# Intent: Public landing page for proxy-enabled installations

**Date:** 2026-11-26
**Status:** approved

## Objective

Let a visitor open the service domain in a browser and see a small local website without entering credentials. Keep proxy forwarding restricted to authorized users.

## Desired Outcomes

| Installation | Browser address with default ports | Expected response |
|---|---|---|
| Proxy only | `https://<domain>/` | HTTP 200 with the local landing page |
| VPN and proxy | `https://<domain>/` and `https://<domain>:8118/` | HTTP 200 with the same local landing page at each address |

- Opening the page requires no login dialog, redirects or third-party requests.
- When the operator selects a custom HTTPS proxy port, a browser can open the page on that port.
- On the proxy endpoint, authenticated clients can fetch both HTTP and HTTPS destinations. A request to forward traffic with missing or invalid proxy credentials receives HTTP 407.

## Health Metrics

- The test destination receives zero forwarded requests from unauthorized clients, including before the first proxy user exists.
- A VLESS client in combined mode can connect and transfer data with its existing link before and after the page is enabled.
- The browser validates the certificate for the configured service domain at each advertised website address.
- Repeating the browser, proxy and VPN checks after restarting the service yields the same results.

## Strategic Context

- Interacts with: visitors, proxy clients, VLESS clients, the installer, the configured service domain, TLS certificates, Nginx and Xray.
- Priority trade-off: preserve authentication and working client connections when choosing how the website shares a listener.

## Constraints

### Steering

- Use a single static page with locally served content. Keep the page independent of the user's proxy account.

### Hard

- Apply the feature to proxy-only and combined installations with an HTTPS proxy. Preserve the existing behavior of VPN-only installations.
- Keep operator-selected ports and existing client credentials. Add no public listening port solely for the website.
- Serve local content on a direct request for the service domain. Require proxy authentication before forwarding traffic to a destination.
- Keep account details, private configuration and operational data out of the page and its assets.

## Autonomy Zones

- Full: choose page layout, wording and local test fixtures.
- Guarded: change internal routing after verifying the browser, authenticated proxy and VPN paths on their shared ports.
- Proposal-first: ask before changing an advertised port, an existing client link, or the authentication contract.
- No autonomy: deploying to a live server or rotating credentials requires separate operator authorization.

## Stop Rules

- Halt if an unauthenticated request reaches the test destination or an existing VPN or proxy client loses access.
- Escalate if serving the page requires taking a port from another service or changing an existing client's settings.
- Done when: the browser, certificate, proxy-authentication and restart checks pass in both modes, including both default combined-mode addresses and a custom HTTPS proxy port. In combined mode the existing VLESS link must also pass the data-transfer check.
