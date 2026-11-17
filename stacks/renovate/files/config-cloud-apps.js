// Renovate self-hosted (global) config for the stacks/renovate
// "renovate-cloud-apps" CronJob: dependency updates for Cloud Users' App
// repos (Cloud backlog B13, Viktor's decision V13: merge every update,
// majors too). Written 2026-11-17 against Renovate 44.240.0 source.
// Mounted from the renovate-cloud-apps ConfigMap at /opt/renovate/config.js.
// The two other jobs keep their own configs (config.js for viktor/infra,
// config-apps.js for Viktor's own app repos); this one shares only the
// image and the wrapper.
//
// Its own Forgejo account, cloud-renovate (restricted, a collaborator of
// enrolled App repos only), and its own Secret, renovate-cloud-env, which
// holds that account's token and nothing else. Users enrol their own repos,
// so this job must never hold renovate-bot's token (it may push to
// viktor/infra, which CI applies) or the GitHub and Docker Hub tokens.
//
// Which repos: autodiscover by the Forgejo topic `cloud-app`. Renovate's
// Forgejo platform searches repos with uid=<cloud-renovate>, so it sees
// only repos where cloud-renovate is a collaborator; `cloud new` and
// `cloud renovate enable` add the topic and the collaborator with the
// User's own token. autodiscoverFilter drops every viktor/* repo as well
// (Renovate on Forgejo has no owner allow-list: autodiscoverNamespaces is
// ignored when autodiscoverTopics is set).
//
// What a User's repo can make this job run: package manager lock file
// updates, with install scripts off (ignoreScripts, allowScripts false),
// no post-upgrade commands (allowedCommands empty) and no plugins. The
// managers are the template's: bun, npm, dockerfile.
//
// The merge gate: every update is grouped into one pull request
// (`renovate/all`) a week, merged by Renovate itself (automergeType pr,
// platformAutomerge false) only when the branch status is green, which
// means every commit status of the head commit is success. Cloud's
// `cloud/build` is one of them: Cloud builds each renovate/* commit as a
// check build that never deploys and posts pending, then success or
// failure. A commit with no status at all reads `unknown`, which Renovate
// maps to pending, so nothing merges before some status exists
// (lib/modules/platform/gitea/index.ts getBranchStatus and gitea-helper.ts
// toRenovateStatusMapping, 44.240.0). Renovate cannot require one named
// status: a repo with other CI that succeeds while Cloud posts nothing
// (builds off, no status token) merges without a Cloud build, and the
// merge's own Deploy is then the only gate. ignoreTests stays false and
// internalChecksAsSuccess false (Renovate's own renovate/* statuses alone
// never count as green). platformAutomerge stays false because Forgejo's
// "merge when checks succeed" merges at once when the branch has no
// required status checks, and App repos have no branch protection.
// Renovate's merge call names no head commit (gitea mergePr sends only
// `Do`), so a push to the branch between the status check and the merge
// would merge unchecked; only cloud-renovate pushes that branch.
//
// `force` holds the gate and the grouping against a repo's own
// renovate.json: Renovate merges `force` back over the config after every
// packageRule it applies (lib/config/utils.ts mergeChildConfig), so a
// repo rule cannot turn on dependencyDashboardApproval, ignoreTests or a
// platform automerge. A repo can still hold a package back with ignoreDeps,
// or turn Renovate off with `enabled: false`.
//
// The one secret comes from env (Secret renovate-cloud-env), never this file:
//   RENOVATE_TOKEN  Forgejo PAT of cloud-renovate (Vault secret/renovate-cloud forgejo_token)
// No github.com or Docker Hub token: release notes are left out, and Docker
// Hub lookups (the oven/bun base image) are anonymous, sharing the home
// address's 100 manifest reads an hour with every anonymous client. The
// lookup cache on the PVC keeps that to a few reads per run.
'use strict';

const WEEKLY = ['* 0-5 * * 1']; // Monday 00:00-05:59 UTC; the CronJob runs 3 times in it

module.exports = {
  platform: 'forgejo',
  endpoint: 'https://forgejo.viktorbarzin.me/api/v1/',
  autodiscover: true,
  autodiscoverTopics: ['cloud-app'],
  autodiscoverFilter: ['!/^viktor\\//'],

  gitAuthor: 'Cloud Renovate <cloud-renovate@viktorbarzin.me>',
  username: 'cloud-renovate',

  enabledManagers: ['bun', 'npm', 'dockerfile'],
  ignoreScripts: true,
  allowScripts: false,
  allowedCommands: [],
  allowPlugins: false,

  // Pushes per run across all repos (a branch push, a rebase). One group
  // per repo, so about 20 repos' weekly branches per run; the rest wait
  // for the next run, 2 hours later, and the window has 3 runs, so about
  // 60 repos get their pull request on Monday. A run stops at the Job's
  // 25-minute deadline; the repos it did not reach wait for the next run.
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
  dependencyDashboard: { enabled: true, title: 'Renovate dashboard' },
  commitBody:
    "Why: Cloud's Renovate job groups every dependency update of the week into one pull request. Cloud builds it as a check build that never deploys, and Renovate merges it once the cloud/build status is success.",

  force: {
    automerge: true,
    automergeType: 'pr',
    platformAutomerge: false,
    ignoreTests: false,
    internalChecksAsSuccess: false,
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
