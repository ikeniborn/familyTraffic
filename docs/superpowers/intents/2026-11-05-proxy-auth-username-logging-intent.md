---
result_check:
  verdict: OK
  source: intent
  intent_hash: 7515993be70fc4b6
  last_run: 2026-11-05
  reviewed: true
  docs_checked: true
workflow:
  route: chain
  continuation: execute
review:
  intent_hash: 7515993be70fc4b6
  last_run: 2026-11-05
  phases:
    structure: { status: passed }
    completeness: { status: passed }
    clarity: { status: passed }
    consistency: { status: passed }
    alignment: { status: passed }
  findings: []
---
# Intent: proxy-auth-username-logging

**Date:** 2026-11-05
**Status:** approved

## Objective

Identify the username supplied during failed proxy authentication for future debugging. Existing events identify only the source IP. Preserve authentication and source attribution while changing the previous username-free journal contract.

## Desired Outcomes

- For parsed invalid HTTP and SOCKS proxy credentials, administrators can read the supplied username alongside the protocol, source IP, and timestamp.
- Client-controlled usernames cannot create extra journal lines or forge Fail2ban events. Passwords and complete authorization headers do not appear in the authentication journal.
- The proxy jail blocks a source after 15 counted failures within 600 seconds. The ban lasts 3600 seconds. Installation and server configuration agree.
- The requested source, 46.158.52.79, is unbanned without adding an allowlist exemption.
- The verified change runs on ikenibornsw. Delivery uses a development branch from test, a PR into test, then a PR from test into master.

## Health Metrics

- Valid proxy credentials continue to authenticate for both HTTP and SOCKS.
- Missing credentials, malformed requests, HTTP challenges, and destination failures retain their existing counting behavior.
- The event source remains the validated numeric TCP peer address. Existing Fail2ban source matching continues to work.
- The journal remains a regular file with mode 0600. Rotation continues to work.
- Existing operator-approved ignoreip entries remain unchanged. SSH and Reality jail behavior remains unchanged.

## Strategic Context

- Interacts with: the pinned Xray authentication patch, the Fail2ban filter and jail generator, deployment scripts, repository tests, and administrators of ikenibornsw.
- Priority trade-off: preserve credential confidentiality and correct blocking before deployment speed.

## Constraints

### Steering

- Extend the current event pipeline with the smallest compatible change.
- Describe logged usernames as supplied identities, not verified people.
- Keep implementation, tests, and documentation scoped to this request.

### Hard

- Never log passwords or full authorization headers.
- Escape and bound client-controlled usernames before writing a single journal event.
- Preserve existing authentication decisions and ban eligibility except for the explicitly requested retry threshold.
- Preserve local changes to .iwiki.toml and operator-managed server exceptions.
- Use dev-proxy-auth-username-logging. Do not push or merge directly into test or master.
- Preserve a rollback path before changing the server runtime.

## Autonomy Zones

- Full autonomy: choose the safe username representation, modify scoped repository files, and run relevant checks.
- Guarded: deploy the verified change to ikenibornsw, including a brief container restart, with rollback available.
- Proposal-first: obtain approval of this checked intent and draft topic profile before implementation. Obtain approval for scope changes.
- No autonomy: expose secrets, discard unrelated user changes, or bypass branch and PR requirements.

## Stop Rules

- Halt if: tests or live checks show secret leakage, forged events, broken valid authentication, or no rollback path.
- Escalate if: implementation requires a broader authentication redesign or the production state prevents a scoped deployment.
- Done when: controlled failed HTTP and SOCKS attempts expose only their supplied usernames, injection tests cannot forge events, valid authentication passes, the live retry threshold is 15, the requested ban is absent, and the PR delivery path is recorded.
- Retain completion-pending while the required iwiki task lifecycle and documentation cannot be delivered.
