// Renovate self-hosted (global) config for the stacks/renovate "renovate-apps"
// CronJob: dependency updates for first-party app repos on the default app
// stack (docs/adr/0001-default-app-stack.md in the monorepo, "Delivery" row).
// Written 2026-10-16 against Renovate 44.115.9 source. The infra job's config
// is config.js next to this file; the two jobs share the renovate-bot account
// and the wrapper, and nothing else.
// Mounted from the renovate-apps ConfigMap at /opt/renovate/config.js.
// Secrets come from env (the shared renovate-env Secret), never from this file:
//   RENOVATE_TOKEN             Forgejo PAT of renovate-bot (secret/renovate forgejo_token)
//   RENOVATE_GITHUB_COM_TOKEN  read-only github.com PAT (secret/viktor ghcr_pull_token):
//                              release notes, the Bun download lookup and the OSV database
//
// The whole policy lives here, so an app repo needs no renovate.json. A repo
// that adds one can still narrow or extend it (repo config merges over this).
//
// Per-repo prerequisites on Forgejo (outside Terraform, like viktor/infra's):
// renovate-bot is a write collaborator, and pull requests are enabled with
// fast-forward-only merges allowed. Renovate aborts a repo that lacks either
// (gitea platform initRepo: REPOSITORY_ACCESS_FORBIDDEN / REPOSITORY_BLOCKED).
'use strict';

module.exports = {
  platform: 'forgejo',
  endpoint: 'https://forgejo.viktorbarzin.me/api/v1/',
  repositories: [
    {
      repository: 'viktor/tasks',
      // Forgejo's default branch for this repo is the stale `main`; the
      // GitHub Actions build and deploy follow `master`.
      baseBranchPatterns: ['master'],
    },
  ],
  autodiscover: false,

  gitAuthor: 'Renovate Bot <renovate-bot@viktorbarzin.me>',
  username: 'renovate-bot',

  // Run limit for this job: every git push counts (a branch push is 1, the
  // fast-forward of master another 1), and the counter is process-wide across
  // all repos. 6 is about three landed bumps per run, four runs a day. Each
  // landed bump starts that app's build and deploy.
  prCommitsPerRunLimit: 6,

  onboarding: false,
  requireConfig: 'optional', // the policy below applies without a repo file

  baseDir: '/tmp/renovate',
  cacheDir: '/tmp/renovate/cache',
  persistRepoData: true,
  repositoryCache: 'enabled',

  // Bun for bun.lock updates. `install` makes containerbase download the exact
  // version the app pins in package.json ("packageManager": "bun@1.4.3" is read
  // as the bun constraint) into cacheDir/containerbase on the PVC, about 40 MB
  // once. The -full image (about 2.6 GB) would be pulled through the registry
  // cache onto whichever node the pod lands on, and carries whatever Bun its
  // tag ships rather than the app's pin.
  binarySource: 'install',
  hostRules: [{ matchHost: 'forgejo.viktorbarzin.me', allowInternal: true }],

  // CVE fixes from osv.dev. They skip minimumReleaseAge (Renovate's
  // vulnerabilityAlerts defaults), but the app's own bunfig.toml wait still
  // applies to `bun install`, so a fix younger than 3 days fails the lock
  // update and stays a branch with an artifact error instead of landing
  // (ADR-0001: urgent fixes go through minimumReleaseAgeExcludes and a manual
  // bump). They also bypass prCommitsPerRunLimit.
  osvVulnerabilityAlerts: true,

  // The Bun manager: package.json files with a sibling bun.lock. A legacy npm
  // or Python build in the same repo is left alone, since each master push
  // deploys it. dockerfile and github-actions are on only for the Bun runtime
  // pins (the packageRules below disable everything else they find).
  enabledManagers: ['bun', 'dockerfile', 'github-actions'],

  // Landing: straight to master, no PR and no review, like viktor/infra
  // (Viktor's call, ADR-0001; no exceptions since 2026-10-18). ignoreTests: these repos report no commit statuses to Forgejo,
  // so Renovate would otherwise wait forever. A failed bun.lock update still
  // blocks the automerge (artifact errors are checked before ignoreTests).
  automerge: true,
  automergeType: 'branch',
  ignoreTests: true,
  rebaseWhen: 'behind-base-branch',
  dependencyDashboard: true,
  dependencyDashboardTitle: 'Renovate dashboard',
  separateMajorMinor: true,
  commitBody:
    'Why: upstream released {{depName}} {{newValue}} ({{updateType}}). The renovate-apps job lands app dependency updates per ADR-0001 (Delivery), after a 3-day wait for npm releases; the app build runs afterwards.',

  packageRules: [
    {
      description:
        'Wait 3 days before taking a new npm release (ADR-0001). Our own @viktorbarzin/* packages are excluded. Matches the app\'s bunfig.toml install.minimumReleaseAge',
      matchDatasources: ['npm'],
      matchPackageNames: ['!@viktorbarzin/**'], // only a negation: every npm package except ours
      minimumReleaseAge: '3 days',
    },
    {
      description:
        'TanStack Start and Router: pinned to exact versions and moved together in one commit. Start ships breaking changes in minor and patch releases; the app CI (lint, typecheck, unit and e2e tests) runs before the deploy job, so a breaking bump stops at CI and the running version stays up. Landed without review since 2026-10-18 (Viktor), like every other update',
      matchDatasources: ['npm'],
      matchPackageNames: ['@tanstack/*start*', '@tanstack/*router*'],
      rangeStrategy: 'pin',
      groupName: 'TanStack Start and Router',
      groupSlug: 'tanstack-start-router',
    },
    {
      description:
        'The Bun runtime: the packageManager / engines pin, the oven/bun base image tags in the Dockerfile and setup-bun\'s bun-version in the GitHub workflow move together in one commit, so the build never runs a different Bun from the one the app pins. The whole group waits 3 days, because a docker tag would otherwise land before the npm release it belongs with',
      matchPackageNames: ['bun', 'oven/bun'],
      groupName: 'Bun runtime',
      groupSlug: 'bun-runtime',
      minimumReleaseAge: '3 days',
    },
    {
      description:
        'The dockerfile and github-actions managers are on for the Bun runtime only. Other base images and actions in an app repo are left alone',
      matchManagers: ['dockerfile', 'github-actions'],
      matchPackageNames: ['!bun', '!oven/bun'],
      enabled: false,
    },
  ],

  logContext: 'renovate-apps',

  // Renovate logs "Reached commits per run limit - skipping branch" at debug
  // (lib/workers/repository/update/branch/index.ts, 44.115.9) and the CronJob
  // logs at info, so a run's log did not show which branches the
  // prCommitsPerRunLimit held back. Raised to info so it does (2026-10-19).
  logLevelRemap: [
    { matchMessage: '/^Reached commits per run limit/', newLogLevel: 'info' },
  ],
};
