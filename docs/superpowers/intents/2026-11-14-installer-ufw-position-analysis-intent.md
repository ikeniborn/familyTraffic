---
workflow:
  route: chain
  continuation: execute
review:
  intent_hash: 5c4a91368b867f6c
  last_run: 2026-11-14
  phases:
    structure: { status: passed }
    completeness: { status: passed }
    clarity: { status: passed }
    consistency: { status: passed }
    alignment: { status: passed }
  findings: []
---
# Intent: installer-ufw-position-analysis

**Date:** 2026-11-14
**Status:** approved

## Objective

Allow installation to configure SSH access and continue on hosts with empty or existing UFW rules. Recover the reported installation failure on ikenibornft4 without requiring manual firewall preparation.

## Desired Outcomes

- Installation succeeds through firewall setup when both address-family rule lists are empty or only one contains rules.
- Installation honors the selected SSH source for TCP port 22. An empty selection permits any source in each enabled address family.
- Installation preserves the current SSH management source and actual server port, including a source or port different from the selection.
- Existing ALLOW, DENY, REJECT, LIMIT, duplicate, and unrelated rules do not cause failure merely because they already exist. Required SSH access takes precedence over conflicting rules, and installation continues.
- Existing unrelated rules retain their content and relative order. Existing broader permissions remain available. Required SSH permissions do not accumulate on repeated installation.
- Both inactive and active UFW configurations are handled. IPv4 and enabled IPv6 receive the intended permissions. An unsupported requested address family produces an explicit diagnostic without falsely reporting success.
- A failed firewall update preserves or restores the previous usable management access. Installation reports an application failure instead of continuing with unverified SSH access.
- Changes are delivered through a PR into test, followed by a separate PR from test into master.

## Health Metrics

- A new SSH connection succeeds after successful host application; the original management session remains usable.
- Unrelated firewall rules retain their content and relative order before and after successful reconciliation.
- A second reconciliation leaves the same effective SSH permissions and rule counts as the first.
- Failure-injection checks show no activation of an unverified inactive firewall and no loss of previously usable management permissions.
- Saved application users, keys, credentials, and service configuration remain unchanged by firewall reconciliation.

## Strategic Context

- Interacts with: install.sh, lib/installer_security.sh, UFW rule persistence and live application, current SSH session detection, firewall tests, operator documentation, and GitHub delivery.
- Priority trade-off: preserve management access and existing unrelated policy while completing installation automatically.

## Constraints

### Steering

- Keep the change within installer firewall reconciliation and its tests and documentation.
- Reuse existing source validation and management-session discovery where they satisfy the accepted outcomes.
- Prefer the smallest approach supported by real UFW behavior.

### Hard

- Preserve unrelated UFW rules and existing broader access. Permit changes to SSH rule priority and necessary SSH conflict reconciliation only for the selected and current management access.
- Never reset or disable the host firewall to resolve rule conflicts.
- Never introduce a delete-then-add interval that removes previously usable management access.
- Preserve application users, keys, credentials, and deployment configuration.
- Validate intended SSH permissions before enabling an inactive firewall or reporting success.
- Keep changes on dev-installer-ufw-position-analysis based on test. Use PRs for delivery into test and master.

## Autonomy Zones

- Full autonomy: perform diagnosis, develop scoped code and tests after the required approvals, and run isolated firewall experiments.
- Guarded: prepare and validate backups, reconciliation, and recovery in disposable environments. Verify any authorized host application through a new SSH connection.
- Proposal-first: obtain approval for the checked intent and profile, the required continuation, and host firewall application. Return changed requirements to the earliest affected gate.
- No autonomy: reset the firewall, discard unrelated rules, delete application identities, change unrelated service configuration, or bypass PR delivery.

## Stop Rules

- Halt if: an update cannot preserve management access, unrelated firewall policy, or saved application identities.
- Escalate if: supported UFW behavior prevents automatic reconciliation within these constraints or recovery verification fails.
- Done when: real-UFW checks cover empty and existing address-family lists, conflicting and duplicate SSH rules, active and inactive firewalls, repeated execution, current-session preservation, and failure recovery; required repository checks pass; documentation matches behavior; both PR deliveries are recorded.
- Retain completion-pending while required verification or durable delivery remains incomplete. Do not claim live host recovery without authorized application and a successful new SSH connection.
