---
chain:
  intent: docs/superpowers/intents/2026-11-26-proxy-public-landing-page-intent.md
review:
  spec_hash: 5437badeca70b108
  last_run: 2026-11-27
  phases:
    structure: { status: passed }
    coverage: { status: passed }
    clarity: { status: passed }
    consistency: { status: passed }
  findings: []
---
# Public landing page for proxy-enabled installations

**Status:** approved

## Browser and proxy contract

A visitor opens the configured service domain over HTTPS. The response to a direct GET of the root is HTTP 200 with one local HTML page. HEAD returns the same status and representation headers with an empty body. Use one HTML asset with inline styles, a descriptive title and locally rendered text. The page has no account form, credentials, service diagnostics or external resources.

| Entry point | Direct browser request to the service domain | Proxy request |
|---|---|---|
| Configured HTTPS proxy port in proxy-only or combined mode | Serve the page | Apply the existing proxy authentication policy |
| Default combined VPN entry on 443 | Serve the same page using the domain certificate | The website route serves local content only. Existing VPN client names keep their routes. |
| Optional plaintext and SOCKS listeners | Preserve their existing protocol handling | Preserve their existing authentication |

With custom ports, advertise the actual HTTPS endpoint. If FamilyTraffic owns no listener on 443, leave that port alone. The VPN-only mode has no website. Port 80 continues to serve its existing certificate challenge workflow.

## Shared HTTPS proxy endpoint

Keep TLS termination and the existing backend connection in the Nginx stream listener. The pinned Xray HTTP receiver already parses each request before checking the proxy account. Add a local response there, scoped to the managed HTTP proxy inbound, a proxy-enabled mode, the configured domain, and the incoming HTTPS proxy port. Use the existing configuration loaded by the application. Keep one authority for proxy credentials and one failure journal.

Distinguish HTTP requests by their request-target form. A direct GET or HEAD with an origin-form target, the configured host, and the correct authority port is eligible for local service. Compare DNS names case-insensitively. An omitted port means 443. Serve the fixed asset for the root path, including a query on that path. Other local paths return 404. A local response ends the request without invoking outbound routing. No path or query from a request selects a filesystem file.

CONNECT and absolute-form requests always follow the existing authentication path, including absolute-form requests addressed to the service domain. Missing or invalid credentials yield 407. Valid credentials retain the existing forwarding behavior. Reuse the parsed request on every iteration of the existing HTTP receiver. A successful local response closes that HTTP/1.1 connection. A browser visit must not create a failed-login event.

Scope the local response using the receiving port reported by the Nginx-to-Xray PROXY connection. The Host header alone cannot establish which listener accepted the connection. Verify the reported destination port in the actual built image with TLS and plaintext listeners enabled together. If the port cannot be established, keep normal proxy authentication. Never enable the page across all HTTP receivers as a fallback.

Adding a separate frontend would introduce another HTTP parser and a handoff for CONNECT, client addresses and authentication failures. Keeping the local response in the existing parser preserves the proxy data path. The cost is maintaining a small additional change against the pinned Xray revision. Apply and test it alongside the existing authentication patch. [HTTP/1.1 request-target forms](https://www.rfc-editor.org/rfc/rfc9112.html#section-3.2)

## Combined VPN entry

On the existing VLESS listener, use the exact service-domain TLS server name to select a private Nginx HTTPS virtual host. Use a Unix socket for that host and the same service certificate and page as the proxy endpoint. Keep the existing Tier 2 routes and default Reality passthrough. The private website virtual host has a fixed document and no outbound proxy handler. Restrict this private virtual host to the configured authority and the same local GET and HEAD behavior as the browser endpoint. Only the existing public listeners appear in the firewall and connection details. [Nginx TLS server-name preread](https://nginx.org/en/docs/stream/ngx_stream_ssl_preread_module.html)

Before changing a combined installation, compare the service domain with the effective Reality server names and enabled transport names. Include names already present in the installed configuration. A name that matches an existing VPN route makes an exact-name split ambiguous. Report the conflicting name and leave the active configuration intact. Resolving such a collision requires an operator decision under the approved intent. Never repoint a working VPN name automatically.

## Packaging and activation

Ship a single project-owned HTML source in the application image. Embed those bytes in the Xray build and install a read-only copy for Nginx from the same source. Keep it independent of the writable ACME webroot. Build and test the image and host configuration generators from the same revision.

The installer and transport regeneration paths share the Nginx generator. Both must apply the same domain, socket, ownership and conflict checks. Preserve the existing configuration inputs and user database. For a legacy installation, use the existing service-settings resolver. Supply the resolved mode, certificate domain and selected HTTPS port to both the generator and the running image. If those values are ambiguous, report the condition and keep the active configuration. Validate the staged configuration with the target image, its certificate mounts and Xray configuration before activation. If validation or reload fails, retain or restore the previous working configuration and verify the running services. An update that only replaces the image does not establish that both combined entry points have been configured.

## Verification and release criteria

| Check | Observable evidence |
|---|---|
| Browser | GET and HEAD on each default address and a custom HTTPS proxy port. Verify the hostname, 200 response, expected page content or empty HEAD body, and no redirect or authentication challenge. Compare the HTML bytes at the two combined addresses. |
| Proxy authorization | Test HTTP absolute-form and HTTPS CONNECT from an external client with absent, incorrect and valid credentials. Count requests at a controlled destination. Refused requests return 407 and its count stays unchanged. Successful requests return the destination's expected response. Include a request before provisioning the first account. |
| Protocol boundaries | Cover an absolute-form request targeting the service domain, a direct request for an unknown local path, plaintext and TLS sharing the private HTTP receiver, and the existing SOCKS and VPN-only behavior. Browser requests must not increment the failed-login journal. |
| Combined routing | Transfer data through an existing VLESS link, open the site at both addresses, then repeat after restart. Recheck enabled Tier 2 transports, listener inventory and certificate challenge handling. |
| Recovery | Exercise a conflicting domain and a rejected configuration reload on an isolated installation. Verify that the previous configuration, credentials and client connections still work. |

Use the patched Xray focused tests, installer and generator tests, and the isolated service-mode runtime suite. End-to-end checks must use the packaged image rather than simulated HTTP status codes. No live deployment is part of specification approval.

## Acceptance (from intent)

| Installation | Browser address with default ports | Expected response |
|---|---|---|
| Proxy only | `https://<domain>/` | HTTP 200 with the local landing page |
| VPN and proxy | `https://<domain>/` and `https://<domain>:8118/` | HTTP 200 with the same local landing page at each address |

- Opening the page requires no login dialog, redirects or third-party requests.
- When the operator selects a custom HTTPS proxy port, a browser can open the page on that port.
- On the proxy endpoint, authenticated clients can fetch both HTTP and HTTPS destinations. A request to forward traffic with missing or invalid proxy credentials receives HTTP 407.

- Done when: the browser, certificate, proxy-authentication and restart checks pass in both modes, including both default combined-mode addresses and a custom HTTPS proxy port. In combined mode the existing VLESS link must also pass the data-transfer check.
