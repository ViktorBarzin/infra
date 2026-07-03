# Valia sites — add / update / retire

Off-infra static sites authored by Valia (ADR-0018, CONTEXT.md "Valia site").
Serving: Cloudflare Pages. Freshness: the `valia-sites-sync` CronJob
(`valia-sites` ns) mirrors each Content folder every 10 minutes and deploys
only when the folder's manifest hash changed. Registry: `local.sites` in
`stacks/valia-sites/main.tf` — one entry per site drives everything (Pages
project, custom domain, public CNAME, internal split-horizon CNAME, sync).

Current sites: `bridge` (ОбУ „Отец Паисий“ — "мост"), `stem95su` (95. СУ STEM
board).

## Add a site

1. Valia shares the Drive folder with **vbarzin@gmail.com** (viewer is enough —
   the pipeline is strictly read-only towards Drive).
2. Get the folder id from its URL (`drive.google.com/drive/folders/<ID>`).
3. Pick the **English** subdomain name (Viktor's call — CONTEXT.md naming rule).
4. Add one entry to `local.sites` in `stacks/valia-sites/main.tf`:

   ```hcl
   <name> = {
     folder_id  = "<ID>"
     src_path   = ""            # or "sub/folder" if servable files live deeper
     entry_file = "index.html"  # or whatever her main HTML file is called
     manage_dns = true
   }
   ```

5. Commit + push; CI applies. Within ~10 min the sync deploys content and the
   site serves at `https://<name>.viktorbarzin.me` (custom-domain TLS takes
   ~5–10 min extra on first attach — CF returns 522 for the hostname until
   then). Internal LAN/VLAN/pod resolution appears when the hourly
   `technitium-ingress-dns-sync` next runs — trigger it early with:
   `kubectl create job --from=cronjob/technitium-ingress-dns-sync valia-dns-now -n technitium`

## Content rules (what Valia's folder must look like)

- The **entry file** must exist — the sync stages a copy as `index.html` at
  deploy time, so `/` works; the original filename keeps working too (deep
  links survive). If the folder is empty or the entry file is missing, the
  sync **skips the site and leaves it as-is** (never wipes a live site).
- Google-native files (Docs/Sheets) are **ignored** (`--drive-skip-gdocs`) —
  only real files (`.html`, images, …) deploy. Gemini's HTML exports are fine.
- Per-file limit 25 MB (Cloudflare Pages), 20k files max — far beyond a
  1-page site.

## Update a site

Nothing to do: Valia edits the folder, the site follows within ~10 minutes.
Force it early: `kubectl create job --from=cronjob/valia-sites-sync sync-now -n valia-sites`

## Rename / retire a site

Rename = retire + add (Pages projects can't be renamed). Retire:

1. Delete the entry from `local.sites`; commit + push. TF destroys the public
   CNAME + custom domain + Pages project; the internal record is removed by
   the next `technitium-ingress-dns-sync` run (its deletion pass drops any
   internal `*.pages.dev` CNAME that left the `valia-sites-dns` ConfigMap —
   scoped so it can never touch non-Pages records).
2. That's all — no manual DNS cleanup (the pre-ADR-0018 add-only gotcha is
   fixed by the deletion pass).

## Failure modes / debugging

- **Visibility is failed-Job-only by choice** (ADR-0018): no alerts, no
  notifications. Check: `kubectl get jobs -n valia-sites | tail`, logs of the
  last `valia-sites-sync-*` pod.
- **Drive auth broken** (`FATAL … Drive list failed`): the shared
  `secret/valia-sites.rclone_conf` token died. The GCP OAuth app
  (`home-lab-1700868541205`) must stay published to "Production" or refresh
  tokens expire weekly (same constraint as the old stem95su conf, which this
  one was copied from). Re-mint and `vault kv patch secret/valia-sites
  rclone_conf=@…`.
- **Wrangler auth broken**: `secret/valia-sites.cloudflare_pages_token` is a
  SCOPED token (Pages Read+Write on the account, id
  `355d2c9d11579bdad1e9498dafca30d5`) — re-mint via
  `POST /user/tokens` with the Global API Key (`secret/platform`), patch
  Vault. Do NOT put the Global API Key in the pod.
- **Site serves stale content**: check the state CM
  (`kubectl get cm valia-sites-state -n valia-sites -o yaml`) — deleting a
  site's key forces a redeploy on the next run.
- **`GUARD … skipping`** in logs: Valia's folder is empty or renamed the
  entry file — the site deliberately kept its last content. Fix the folder or
  update `entry_file`.

## History

- stem95su still serves from its ORIGINAL in-cluster stack (nginx + NFS +
  its own rclone CronJob): its Pages cutover is **parked** (`manage_dns =
  false`) because `stem_board.html` embeds the 42.9 MB `stem_video.mp4`,
  over the 25 MB Pages per-file cap — the sync guard-skips it until the
  video shrinks below 25 MB (or the site is deliberately kept in-cluster
  and removed from the map). Once cut over: flip `manage_dns = true`,
  set `dns_type = "none"` in `stacks/stem95su`, then retire that stack;
  `secret/stem95su` becomes superseded by `secret/valia-sites`.
- bridge started as a hand-deployed wrangler experiment (2026-07-03, memory
  id 7085) and was adopted into the stack the same day.
