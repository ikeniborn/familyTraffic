---
result_check:
  verdict: OK
  source: intent
  intent_hash: 7a1b35016547b265
  last_run: 2026-11-27
  reviewed: true
  docs_checked: true
workflow:
  route: chain
  continuation: execute
review:
  intent_hash: 7a1b35016547b265
  last_run: 2026-11-27
  phases:
    structure: { status: passed }
    completeness: { status: passed }
    clarity: { status: passed }
    consistency: { status: passed }
    alignment: { status: passed }
  findings: []
---
# Intent: Trusted firewall source and explicit HTTPS proxy port

**Date:** 2026-11-27
**Status:** approved

## Objective

Let the operator reach host services from the address selected during firewall setup. Give proxy users a complete connection URL that includes the configured port, including the HTTPS default.

## Desired Outcomes

- When the operator explicitly supplies a trusted IP address or CIDR during interactive or unattended installation, UFW permits inbound host traffic from that source across all ports and protocols in its address family. The prompt explains the scope of the grant.
- An empty selection retains the existing SSH default. The installer preserves access for the current SSH connection on its actual port. Detecting that connection alone grants no access to other host ports.
- The selected permission is effective after setup and after a UFW reload. Running setup again with the same input leaves a single equivalent managed grant.
- User creation, display and client export render an HTTPS proxy on port 443 as `https://user:password@host:443`. The same outputs show the configured port for other HTTPS ports.

## Health Metrics

- A test client in the selected network reaches a non-SSH host service. A client outside that network remains subject to its previous policy.
- The firewall keeps unrelated rules and preserves the working SSH path on activation or rollback. IPv4 and IPv6 grants apply only to the selected address family.
- Proxy authentication and credential-file permissions retain their existing behavior. Updating the URL format preserves the stored credentials.

## Strategic Context

- Interacts with: installer prompts, unattended firewall configuration, UFW, SSH, proxy user management and client exports.
- Priority trade-off: limit the broader host permission to the operator's explicit selection while retaining management access.

## Constraints

### Steering

- Use the same meaning for a trusted source in the prompt, installer summary and deployment guide.
- Keep the URL format consistent wherever the operator obtains a proxy connection link.

### Hard

- Apply the grant to incoming traffic destined for the host. Preserve the forwarding and outgoing policies.
- Preserve unrelated firewall rules, existing service port choices and proxy access controls.
- Deliver via a feature PR into test and a release PR from test into master.

## Autonomy Zones

- Full: choose test fixtures, output examples and wording.
- Guarded: change the managed UFW rules after verifying persistence, scope and SSH access in an isolated environment.
- Proposal-first: changing the access granted by an empty input or a detected SSH peer requires operator approval.
- No autonomy: changing firewall rules directly on ft2 requires separate authorization.

## Stop Rules

- Halt if the new permission reaches addresses outside the selected source or interrupts the existing SSH management path.
- Escalate if the requested grant would require changing unrelated operator rules.
- Done when: isolated firewall checks pass before and after reload, generated HTTPS proxy links contain their explicit ports, and the verified release reaches master through test.
