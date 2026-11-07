---
workflow:
  route: chain
  continuation: execute
result_check:
  verdict: needs_work
  source: intent
  intent_hash: f8836cd1e0648240
  last_run: 2026-11-07
  reviewed: true
  docs_checked: true
  pending: PR delivery to test and master
review:
  intent_hash: f8836cd1e0648240
  last_run: 2026-11-07
  phases:
    structure: { status: passed }
    completeness: { status: passed }
    clarity: { status: passed }
    consistency: { status: passed }
    alignment: { status: passed }
  findings: []
---
# Intent: fail2ban-address-allowlist

**Date:** 2026-11-07
**Status:** approved

## Objective

Prevent trusted administrator addresses from being banned by Fail2ban. Allow operators to configure trusted addresses during installation.

## Desired Outcomes

- Both ikenibornft2 and ikenibornft3 exempt 78.107.114.37 from SSH and proxy authentication bans after configuration reloads.
- The installer accepts a whitespace-separated list of IPv4, IPv6, and CIDR addresses for SSH and proxy authentication exclusions.
- Empty input and repeated installations preserve existing exclusions. New addresses extend existing exclusions.
- Invalid input is rejected before Fail2ban configuration changes. Other addresses retain existing ban thresholds and protection.
- Reviewed changes reach test and master through pull requests, with verification evidence attached.

## Health Metrics

- Proxy maxretry remains 15, findtime remains 600 seconds, and bantime remains 3600 seconds.
- Existing SSH jail thresholds and existing operator exclusions remain unchanged.
- Fail2ban configuration validation succeeds after changes. Enabled SSH and proxy jails remain operational.
- Focused tests and the final unit suite pass for the final implementation state.

## Strategic Context

- Interacts with: installer security configuration, Fail2ban setup, proxy security verification, and host SSH administration.
- Priority trade-off: trust before speed and cost. Preserve protection for addresses outside the allowlist.

## Constraints

### Steering (behavioral guidance)

- Follow existing installer prompts and configuration conventions.
- Keep changes limited to allowlist configuration, relevant tests, documentation, and delivery artifacts.

### Hard (architectural enforcement)

- Do not hard-code 78.107.114.37 in installer defaults.
- Preserve loopback and existing operator exclusions for each affected jail.
- Do not change firewall admission rules or ban thresholds.
- Validate address input before persisting it. Do not accept configuration directives as addresses.
- Use a dev branch based on test. Deliver through PRs to test and master. Do not push directly to either target.

## Autonomy Zones

- Full autonomy (reversible, low risk): repository inspection, scoped implementation, tests, documentation, and PR preparation.
- Guarded (log + confidence threshold): persist the explicitly requested host exclusions after configuration validation; verify live jail state.
- Proposal-first (needs approval): changes to approved intent, additional protected services, or broader security policy changes.
- No autonomy (human only): deleting unrelated configuration, weakening ban thresholds, or bypassing required repository checks.

## Stop Rules

- Halt if: existing operator exclusions cannot be preserved or effective Fail2ban configuration is invalid.
- Escalate if: host access fails, required verification fails without a bounded diagnosis, or PR delivery requires broader changes.
- Done when: trusted addresses appear in live SSH and proxy exclusions on both hosts, installer tests prove accepted and rejected input behavior and preservation, the final unit suite passes, and changes reach test and master through PRs.
