// Renovate self-hosted (global) config for the stacks/renovate CronJob.
// Written 2026-10-10 against Renovate 44.115.9 source. The repo config is
// renovate.json5 at the repo root; this file holds runtime-only options.
// Mounted from a ConfigMap at /opt/renovate/config.js (RENOVATE_CONFIG_FILE).
// Secrets come from env (ESO -> Secret renovate-env -> envFrom), never from this file:
//   RENOVATE_TOKEN                 Forgejo PAT of renovate-bot (secret/renovate forgejo_token)
//   RENOVATE_GITHUB_COM_TOKEN      read-only github.com PAT, read:packages scope only
//                                  (secret/viktor ghcr_pull_token): release-note links and
//                                  the authenticated GitHub API rate limit
//   DOCKERHUB_USERNAME / DOCKERHUB_TOKEN   not wired today; setting both in the
//                                  ExternalSecret lifts Docker Hub's anonymous limit
'use strict';

const hostRules = [
  // forgejo.viktorbarzin.me resolves to a private address on our network.
  // Renovate 44 warns on every request to it ("internalHostAccess=block would
  // refuse", seen in the 2026-10-10 dry run) and the default becomes `block`
  // in a future major, which would stop Renovate cold.
  { matchHost: 'forgejo.viktorbarzin.me', allowInternal: true },
];
if (process.env.DOCKERHUB_USERNAME && process.env.DOCKERHUB_TOKEN) {
  hostRules.push({
    hostType: 'docker',
    matchHost: 'docker.io',
    username: process.env.DOCKERHUB_USERNAME,
    password: process.env.DOCKERHUB_TOKEN,
  });
}

module.exports = {
  platform: 'forgejo',
  // Renovate strips a trailing /api/v1 and re-adds it; either form works.
  endpoint: 'https://forgejo.viktorbarzin.me/api/v1/',
  // token: from RENOVATE_TOKEN
  repositories: ['viktor/infra'],
  autodiscover: false,

  // Must match the Forgejo account (full name + email set on the account).
  // The rails key on this author; Renovate would otherwise derive it from the
  // account's profile at startup.
  gitAuthor: 'Renovate Bot <renovate-bot@viktorbarzin.me>',
  username: 'renovate-bot',

  // Exactly one bump lands per CronJob run. Every git push counts: the
  // renovate/<dep> branch push is 1, the fast-forward of master is 2. Once the
  // count is >= 1, processBranch() skips every further branch with
  // 'commit-per-run-limit-reached', including in the repository job Renovate
  // restarts once after an automerge (workers/repository/index.ts). The counter
  // is process-wide and set once in workers/global/initialize.ts.
  prCommitsPerRunLimit: 1,

  onboarding: false,
  requireConfig: 'required', // no renovate.json5 on master -> do nothing
  // Only inherited presets from this Forgejo; never fetch presets from github.com.
  // (local> resolves against platform=forgejo.)

  // Caches on the CronJob's PVC so 30-minute runs do not re-clone or re-query
  // every registry. Without it each run is a cold clone + ~300 lookups.
  baseDir: '/tmp/renovate',
  cacheDir: '/tmp/renovate/cache',
  persistRepoData: true,
  repositoryCache: 'enabled',

  binarySource: 'global', // no lockfiles in infra, so no tool downloads needed
  hostRules,

  // Vulnerability alerts bypass prCommitsPerRunLimit (processBranch skips the
  // Commits check when isVulnerabilityAlert). Forgejo has no alert API, and
  // osvVulnerabilityAlerts stays off so nothing reintroduces that bypass.
  osvVulnerabilityAlerts: false,

  // Fail loudly: any ERROR-level log makes renovate exit 1, which the wrapper
  // treats as a failed run (no liveness push).
  logContext: 'renovate-infra',
};
