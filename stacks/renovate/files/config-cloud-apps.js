// Renovate self-hosted (global) config for the stacks/renovate
// "renovate-cloud-apps" CronJob: dependency updates for Cloud Users' App
// repos (Cloud backlog B13, Viktor's decision V13: merge every update,
// majors too). Written 2026-11-17 against Renovate 44.240.0 source.
// Mounted from the renovate-cloud-apps ConfigMap at /opt/renovate/config.js.
// The two other jobs keep their own configs (config.js for viktor/infra,
// config-apps.js for Viktor's own app repos); this one shares only the
// renovate-bot account, the renovate-env Secret and the wrapper.
//
// Which repos: autodiscover by the Forgejo topic `cloud-app`. Renovate's
// Forgejo platform searches repos with uid=<renovate-bot>, so it sees only
// repos where renovate-bot is a collaborator; `cloud new` and `cloud
// renovate enable` add the topic and the collaborator with the User's own
// token. autodiscoverFilter drops every viktor/* repo, so this job never
// touches Viktor's repos even if one carries the topic (Renovate on Forgejo
// has no owner allow-list: autodiscoverNamespaces is ignored when
// autodiscoverTopics is set).
//
// The merge gate: every update is grouped into one pull request
// (`renovate/all`) a week, merged by Renovate itself (automergeType pr,
// platformAutomerge false) only when the branch status is green. Renovate's
// Forgejo platform reads the commit's combined status: a commit with no
// status at all reads `unknown`, which Renovate maps to pending (yellow),
// so nothing merges before Cloud posts `cloud/build` (lib/modules/platform/
// gitea/index.ts getBranchStatus and gitea-helper.ts
// toRenovateStatusMapping, 44.240.0). Cloud builds each renovate/* commit
// as a check build that never deploys and posts pending, then success or
// failure. ignoreTests stays false. platformAutomerge stays false because
// Forgejo's own "merge when checks succeed" merges at once when the branch
// has no required status checks, and App repos have no branch protection.
//
// `force` holds the gate and the grouping against a repo's own
// renovate.json: Renovate merges `force` back over the config after every
// packageRule it applies (lib/config/utils.ts mergeChildConfig), so a
// repo rule cannot turn on dependencyDashboardApproval, ignoreTests or a
// platform automerge. A repo can still hold a package back with ignoreDeps,
// or turn Renovate off with `enabled: false`.
//
// Secrets come from env (the shared renovate-env Secret), never this file:
//   RENOVATE_TOKEN             Forgejo PAT of renovate-bot (secret/renovate forgejo_token)
//   RENOVATE_GITHUB_COM_TOKEN  read-only github.com PAT: release notes and lookups
'use strict';

const WEEKLY = ['* 0-5 * * 1']; // Monday 00:00-05:59 UTC; the CronJob runs 3 times in it

module.exports = {
  platform: 'forgejo',
  endpoint: 'https://forgejo.viktorbarzin.me/api/v1/',
  autodiscover: true,
  autodiscoverTopics: ['cloud-app'],
  autodiscoverFilter: ['!/^viktor\\//'],

  gitAuthor: 'Renovate Bot <renovate-bot@viktorbarzin.me>',
  username: 'renovate-bot',

  // Pushes per run across all repos (a branch push, a rebase). One group
  // per repo, so this is about 20 repos' weekly branches per run; the rest
  // wait for the next run, 2 hours later.
  prCommitsPerRunLimit: 20,
  prHourlyLimit: 0,
  prConcurrentLimit: 0,

  onboarding: false,
  requireConfig: 'optional',

  baseDir: '/tmp/renovate',
  cacheDir: '/tmp/renovate/cache',
  persistRepoData: true,
  repositoryCache: 'enabled',
  // Lock files (bun.lock, package-lock.json, ...) are updated with the
  // tool version the repo pins, installed by containerbase into cacheDir.
  binarySource: 'install',
  hostRules: [{ matchHost: 'forgejo.viktorbarzin.me', allowInternal: true }],

  timezone: 'UTC',
  schedule: WEEKLY,
  // A check build that failed stays failed until the branch changes; a
  // stale but mergeable branch merges without a rebase, and the merge's own
  // build is the Deploy gate (a failed /healthz never goes live).
  rebaseWhen: 'conflicted',
  dependencyDashboard: true,
  dependencyDashboardTitle: 'Renovate dashboard',
  commitBody:
    "Why: Cloud's Renovate job groups every dependency update of the week into one pull request. Cloud builds it as a check build that never deploys, and Renovate merges it once the cloud/build status is success.",

  force: {
    automerge: true,
    automergeType: 'pr',
    platformAutomerge: false,
    ignoreTests: false,
    dependencyDashboardApproval: false,
    groupName: 'all dependencies',
    groupSlug: 'all',
    separateMajorMinor: false,
    separateMultipleMajor: false,
    separateMinorPatch: false,
    schedule: WEEKLY,
  },

  packageRules: [
    {
      description:
        "@viktorbarzin/* packages come from Forgejo's npm registry, where the template installs them from (app-kit ADR-0003)",
      matchDatasources: ['npm'],
      matchPackageNames: ['@viktorbarzin/**'],
      registryUrls: ['https://forgejo.viktorbarzin.me/api/packages/viktor/npm/'],
    },
    {
      description:
        "Wait 3 days before taking a new npm release, except our own packages. Matches the template's bunfig.toml install.minimumReleaseAge, so the lock file update does not fail",
      matchDatasources: ['npm'],
      matchPackageNames: ['!@viktorbarzin/**'],
      minimumReleaseAge: '3 days',
    },
  ],

  logContext: 'renovate-cloud-apps',
  logLevelRemap: [
    { matchMessage: '/^Reached commits per run limit/', newLogLevel: 'info' },
  ],
};
