---
result_check:
  verdict: needs_work
  source: intent
  intent_hash: 36706f0ef0e6019e
  last_run: 2026-11-06
  reason: User approved all-user removal amendment; implementation verification and PR delivery remain pending.
workflow:
  route: chain
  continuation: execute
review:
  intent_hash: 36706f0ef0e6019e
  last_run: 2026-11-06
  phases:
    structure: { status: passed }
    completeness: { status: passed }
    clarity: { status: passed }
    consistency: { status: passed }
    alignment: { status: passed }
  findings: []
---
# Intent: installer-deployment-recovery

**Date:** 2026-11-06
**Status:** approved

## Objective

Recover the failed master installer deployment on ikenibornvpn. Remove the requirement to configure UFW manually before installation. Configure the proxy mode selected during installation without requiring an initial proxy user. Add users later with an explicit choice of proxy access. Permit explicit removal of every user, including the last proxy user, while keeping empty proxies locked.

## Desired Outcomes

- Installation requests an optional SSH source address for TCP port 22. Empty input allows any source. Existing UFW rules and current SSH access remain available.
- Installation establishes SSH access before enabling inactive UFW and proceeds without the previous active-UFW error.
- On a journal-only host, the enabled sshd Fail2ban jail reads systemd journal. Fail2ban configuration validation and proxy monitoring succeed.
- When proxy mode is selected, installation prepares and preserves that proxy configuration without requiring an initial user. Until an authorized proxy user exists, proxy requests cannot reach destinations.
- Later user creation offers proxy access or no proxy access. A proxy-enabled user receives working authenticated proxy access without reinstalling the server. A user without proxy access receives no proxy credentials.
- Explicit removal of the last proxy user succeeds, leaves no saved proxy users, and restores the closed proxy setup state. Concurrent removals can delete every user without exposing anonymous proxy access. A failed activation or database write preserves the removed user and restores configuration.
- The existing saved account, keys, and configuration on ikenibornvpn survive recovery. The container runs from a reviewed prebuilt image and passes service and security checks.
- Changes reach test through a PR from dev-installer-deployment-recovery, then reach master through a second PR.

## Health Metrics

- A new SSH connection succeeds after firewall changes. Existing UFW rules are preserved.
- Saved users and Reality keys retain their pre-recovery hashes.
- Anonymous HTTP and SOCKS requests cannot reach proxy destinations. Valid saved credentials continue to authenticate.
- Fail2ban configuration validation succeeds and enabled jails monitor their intended sources.

## Strategic Context

- Interacts with: the installer, parameter collection, configuration generators, UFW, Fail2ban, the security deployment transaction, Docker, and GitHub PR delivery.
- Priority trade-off: restore service promptly; obtain approval for disputed changes instead of bypassing protection.

## Constraints

### Steering

- Keep changes local to the reproduced installer failures and requested setup choices.
- Reuse existing configuration, account provisioning, and deployment helpers.

### Hard

- Preserve existing UFW rules and current SSH access.
- Preserve saved users, credentials, and Reality keys during installation and host recovery. Delete users only through an explicit removal command. Preserve unrelated repository changes.
- Never start public HTTP or SOCKS proxies without authentication.
- Use a prebuilt image on the server. Do not build application images there.
- Keep recovery backups until live verification succeeds.
- Use the test base and PR delivery path. Do not push directly to test or master.

## Autonomy Zones

- Full autonomy: perform scoped diagnosis, edit installer code and tests, and run local verification.
- Guarded: configure the sshd journal backend, recover the existing deployment, and verify service and protection with backups available.
- Proposal-first: obtain approval for this checked intent and draft profile, disputed changes, and any expansion of scope.
- No autonomy: delete saved users or keys, remove operator UFW rules, expose anonymous proxies, or bypass PR delivery.

## Stop Rules

- Halt if: a change would remove existing SSH access, alter saved identities outside an explicit user-removal command, expose anonymous proxies, or discard the recovery backup.
- Escalate if: recovery requires changes outside these boundaries or live verification fails after focused diagnosis.
- Done when: the installer tests cover both SSH source choices, installation without an initial user, later user creation with and without proxy access, and last/concurrent user removal to a locked empty state; ikenibornvpn accepts a new SSH session, runs the container, and passes security checks; identity hashes remain unchanged; both PR deliveries are recorded.
- Retain completion-pending while required verification or durable wiki delivery remains incomplete.
