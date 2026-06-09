# Post-Mortem Writer

Generate a structured post-mortem document after an incident mitigation session.

## When to use
- After `/post-mortem` command
- Auto-suggested when cluster health transitions from UNHEALTHY → HEALTHY

## Instructions

1. **Gather context**:
   - Run `.claude/scripts/sev-context.sh` to capture current cluster state
   - Review the conversation history for: what broke, timeline, root cause, what was fixed
   - Check existing post-mortems at `docs/post-mortems/` for format reference

2. **Generate the post-mortem**:
   - Use the template at `.claude/skills/post-mortem/template.md`
   - Fill in all sections from the investigation context
   - **Critical**: In the Prevention Plan tables, set the `Type` column correctly:
     - `Alert` — add/modify Prometheus alerting rules (auto-implementable)
     - `Config` — change Terraform config, NFS options, etc. (auto-implementable)
     - `Monitor` — add Uptime Kuma monitors (auto-implementable)
     - `Architecture` — storage migration, stack redesign (human-only)
     - `Investigation` — needs further research (human-only)
     - `Runbook` — document a procedure (human-only)
     - `Migration` — data or service migration (human-only)
   - Items already fixed during the session should have Status = `Done`
   - Items not yet done should have Status = `TODO`

3. **File naming**: `docs/post-mortems/<YYYY-MM-DD>-<slug>.md`
   - Slug: lowercase, hyphenated, max 5 words describing the incident

4. **Update index**: Add an entry to `docs/post-mortems/index.html`
   - Add a new card in the incidents grid with date, severity tag, title, description

5. **Link to GitHub Issue** (if an issue exists for this incident):
   - Fill in the `Issue` field in the template metadata table with `[#N](https://github.com/ViktorBarzin/infra/issues/N)`
   - Add a comment to the GitHub Issue linking the postmortem:
     ```bash
     GITHUB_TOKEN=$(vault kv get -field=github_pat secret/viktor)
     curl -s -X POST \
       -H "Authorization: token $GITHUB_TOKEN" \
       -H "Accept: application/vnd.github.v3+json" \
       "https://api.github.com/repos/ViktorBarzin/infra/issues/<N>/comments" \
       -d '{"body": "**Postmortem:** [View postmortem](https://viktorbarzin.github.io/infra/post-mortems/<YYYY-MM-DD>-<slug>)"}'
     ```
   - Add the `postmortem-done` label and remove `postmortem-required`:
     ```bash
     curl -s -X POST \
       -H "Authorization: token $GITHUB_TOKEN" \
       "https://api.github.com/repos/ViktorBarzin/infra/issues/<N>/labels" \
       -d '{"labels": ["postmortem-done"]}'
     curl -s -X DELETE \
       -H "Authorization: token $GITHUB_TOKEN" \
       "https://api.github.com/repos/ViktorBarzin/infra/issues/<N>/labels/postmortem-required"
     ```
   - If no issue exists, create one with labels `incident`, `sev<N>`, `postmortem-done`

6. **Commit and push**:
   ```
   git add docs/post-mortems/<file>.md docs/post-mortems/index.html
   git commit -m "docs: post-mortem for <date> <title> [ci skip]"
   git push origin master
   ```
   - Use `[ci skip]` to avoid triggering app-stacks pipeline
   - NOTE: The postmortem-todos Woodpecker pipeline WILL trigger (it has its own path filter)

## Type Reference for Prevention Plan

| Type | Auto-implementable? | Examples |
|------|---------------------|----------|
| Alert | Yes | Add PrometheusRule, modify alert thresholds |
| Config | Yes | Change Terraform variables, mount options, CronJob schedules |
| Monitor | Yes | Add Uptime Kuma HTTP/TCP monitor |
| Architecture | No | Migrate storage class, redesign HA topology |
| Investigation | No | Research kernel bug, check Proxmox forum |
| Runbook | No | Document recovery procedure |
| Migration | No | Move data between storage backends |
