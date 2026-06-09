---
name: iterative-plan-review-with-subagents
description: |
  Design pattern for reviewing implementation plans using parallel subagent reviewers
  with iterative refinement. Use when: (1) designing a complex infrastructure change
  that needs security + implementation review, (2) creating a migration plan with
  multiple phases, (3) any plan where missing a critical issue could cause data loss
  or security exposure. Spawns 2 reviewer agents (security + implementation), collects
  CRITICAL/IMPORTANT/NIT findings, fixes all CRITICALs, re-runs until zero CRITICALs.
  Typically converges in 2-3 iterations.
author: Claude Code
version: 1.0.0
date: 2026-03-07
---

# Iterative Plan Review with Subagents

## Problem
Complex infrastructure plans have blind spots — security issues, implementation
incompatibilities, race conditions, format mismatches. A single reviewer misses things.
Multiple reviewers with different expertise catch more.

## Context / Trigger Conditions
- Writing a migration plan (e.g., secrets management, storage migration)
- Designing a multi-phase infrastructure change
- Any plan where a missed issue = downtime, data loss, or security exposure
- User explicitly asks for plan review

## Solution

### 1. Write the plan as a markdown document
Save to `docs/plans/YYYY-MM-DD-<topic>.md`

### 2. Spawn 2 reviewer agents in parallel
```
Agent 1: Security reviewer
- Focus: secret exposure, access control, key management, CI pipeline security
- Classify each finding: CRITICAL / IMPORTANT / NIT

Agent 2: Implementation reviewer
- Focus: format compatibility, race conditions, ordering, tool behavior
- Classify each finding: CRITICAL / IMPORTANT / NIT
```

Key: give each reviewer specific focus areas and the actual source code to check against.

### 3. Consolidate and fix CRITICALs
- Merge findings from both reviewers
- Deduplicate (both often find the same issue)
- Fix ALL CRITICALs in the plan document
- Note IMPORTANTs for implementation phase

### 4. Re-run reviewers on the updated plan
- Same 2 agents, but tell them which CRITICALs were fixed
- Ask them to VERIFY fixes are correct AND find new issues
- Repeat until zero CRITICALs

### 5. Typical convergence
- v1: 5-6 CRITICALs (format issues, race conditions, missing steps)
- v2: 2-3 CRITICALs (fixes introduced new issues, missed edge cases)
- v3: 0 CRITICALs, only IMPORTANTs remaining

## Example Findings from Real Usage (SOPS migration)

| Iteration | CRITICALs Found | Examples |
|-----------|----------------|---------|
| v1 | 6 | YAML≠HCL format, `git add .` commits secrets, no branch protection, parallel race condition |
| v2 | 3 | `SOPS_AGE_KEY_FILE` misunderstanding, `renew-tls.yml` not updated, plan leaks in PR logs |
| v3 | 0 | All verified fixed. 6 IMPORTANTs noted for implementation. |

## Verification
- Zero CRITICALs from both reviewers on the final iteration
- IMPORTANTs documented as implementation notes (not blockers)

## Notes
- Use `sonnet` model for reviewers (fast, thorough enough for review)
- Give reviewers actual source code paths to read, not just the plan
- Tell v2+ reviewers what was fixed so they verify, not re-discover
- The final review should say "ONLY report CRITICALs" to avoid noise
- This pattern cost ~$3-5 in API calls but caught issues that would have caused hours of debugging
