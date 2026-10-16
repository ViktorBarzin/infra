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

  // Only the Bun manager: package.json files with a sibling bun.lock. A legacy
  // npm or Python build in the same repo (tasks' frontend/ and backend/ until
  // cutover) is left alone, since each master push deploys it.
  enabledManagers: ['bun'],

  // Landing: straight to master, no PR, like viktor/infra (Viktor's call,
  // ADR-0001). ignoreTests: these repos report no commit statuses to Forgejo,
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
        'TanStack Start and Router: pinned to exact versions and never automerged. Start ships breaking changes in minor and patch releases, so Renovate opens one PR for both and a person merges it (ADR-0001)',
      matchDatasources: ['npm'],
      matchPackageNames: ['@tanstack/*start*', '@tanstack/*router*'],
      rangeStrategy: 'pin',
      automerge: false,
      groupName: 'TanStack Start and Router',
      groupSlug: 'tanstack-start-router',
    },
    {
      description:
        'The Bun runtime pin (packageManager / engines) moves with the devvm playbook, CI setup-bun and the oven/bun base image (ADR-0001), so a bump is a PR for a person, not a landed commit',
      matchPackageNames: ['bun'],
      matchDepTypes: ['packageManager', 'engines'],
      automerge: false,
    },
  ],

  logContext: 'renovate-apps',
};
