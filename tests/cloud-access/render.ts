/**
 * Renders one Project with Cloud's own renderer (the cloud repo's
 * src/reconciler/render.ts and its test fixtures), for cloud-access.test.sh.
 *
 * Usage: bun render.ts <cloud repo> <out dir>
 *
 * Writes into <out dir>:
 *   main.tf.json           the root module, without the pg backend (the test
 *                          runs `tofu test`, which keeps state in memory)
 *   terraform.tfvars.json  the Project's variables
 *   contract.json          the names infra matches: the edge and
 *                          oauth2-proxy images, the egress exclusions, the
 *                          strip list, the Authentik slug, the namespace and
 *                          the ServersTransport the edge Service names
 *
 *   migrate-job.json       the migrate Job Cloud starts for a Deploy of the
 *                          public App (src/reconciler/migrate-job.ts, B16)
 *   one-off-job.json       a one-off job of the public App, as the reconciler
 *                          starts it for `cloud run` (src/reconciler/job-runs.ts,
 *                          B20)
 *   toolbox-job.json       the psql toolbox Job of a session on the Postgres,
 *                          as the reconciler starts it for `cloud psql`
 *                          (src/reconciler/toolbox.ts, B22)
 *   pg-tasks.json          the Postgres task Jobs and their Secrets, by kind
 *                          (src/reconciler/pg-task-jobs.ts, B28b and B28c),
 *                          and the image they pin
 *   fixtures/<n>/          the same two files for each of Cloud's snapshot
 *                          fixtures (render.fixtures.ts FIXTURES), and
 *   fixtures.json          [{dir, name, namespace}] listing them in order
 *
 * The combined Project holds a private App, a public App connected to a
 * Postgres Service and to an internal App (with a built image, a migrate
 * init container, HTTP health check probes and 2 instances, so a
 * PodDisruptionBudget), the internal App (no edge,
 * oauth2-proxy or Ingress) and
 * the Postgres Service, so every object kind Cloud renders appears at least
 * once; the forbidden variants are built from it. tests/cloud-calico
 * checks the internal App's callers against it.
 * The fixtures are the shapes Cloud's own tests render (a Postgres-only
 * Project, a single App, a Service removed, hostile env values), so each one
 * is applied as well and its objects must be admitted as they are.
 */
import { mkdir, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";

const [repoArg, outArg] = process.argv.slice(2);
if (!repoArg || !outArg) {
	console.error("usage: bun render.ts <cloud repo> <out dir>");
	process.exit(2);
}
const repo = resolve(repoArg);
const out = resolve(outArg);

const renderer = await import(join(repo, "src/reconciler/render.ts"));
const fixtures = await import(join(repo, "src/reconciler/render.fixtures.ts"));
const appConfig = await import(join(repo, "src/app.config.ts"));

const spec = {
	project: fixtures.CTX.project,
	services: {
		recipes: fixtures.app({
			access: "private",
			size: "nano",
			allow: ["ana@example.com"],
		}),
		// A built image, so its migrations render as init container migrate
		// and its health check as httpGet probes (the placeholder runs
		// neither). The image need not exist: the test checks admission, not
		// that the App runs.
		menu: fixtures.app({
			access: "public",
			size: "nano",
			connects: ["db", "pricing"],
			migrate: ["entrypoints/migrate.js"],
			healthCheckPath: "/healthz",
			// Two App pods and the PodDisruptionBudget that keeps one.
			instances: 2,
		}),
		// Internal: only menu reaches it, on the App port.
		pricing: fixtures.app({ access: "internal", size: "nano" }),
		db: { kind: "postgres", size: "small" },
	},
};
const MENU_IMAGE =
	"ghcr.io/viktorbarzin/cloud-recipe-box_menu@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

async function writeRoot(dir: string, projectFile: unknown, images = {}) {
	const r = renderer.render(projectFile, {
		...fixtures.CTX,
		images: { ...fixtures.CTX.images, ...images },
	});
	const main = structuredClone(r.mainTfJson);
	delete main.terraform.backend;
	await mkdir(dir, { recursive: true });
	await writeFile(join(dir, "main.tf.json"), JSON.stringify(main, null, 2));
	await writeFile(
		join(dir, "terraform.tfvars.json"),
		JSON.stringify(r.tfvarsJson, null, 2),
	);
	return r;
}

const rendered = await writeRoot(out, spec, { menu: MENU_IMAGE });

// The migrate Job Cloud starts for a Deploy of menu (B16), built by Cloud's
// own code from menu's rendered variables. A cloud checkout from before B16
// has no migrate-job.ts and writes none.
const migrateJobFile = join(repo, "src/reconciler/migrate-job.ts");
if (await Bun.file(migrateJobFile).exists()) {
	const { migrateJob } = await import(migrateJobFile);
	const { APP_EPHEMERAL } = await import(join(repo, "src/lib/plan.ts"));
	const job = migrateJob({
		namespace: rendered.namespace,
		project: rendered.tfvarsJson.project,
		app: "menu",
		deployId: "0f9a8b7c-1d2e-4f30-8a9b-0c1d2e3f4a5b",
		args: ["entrypoints/migrate.js"],
		vars: rendered.tfvarsJson.apps.menu,
		appPort: fixtures.INSTANCE.appPort,
		ephemeral: APP_EPHEMERAL,
		activeDeadlineSeconds: 900,
	});
	await writeFile(join(out, "migrate-job.json"), JSON.stringify(job, null, 2));
}

// A one-off job of menu (B20), built by Cloud's own code as its job loop
// builds it: the App's rendered variables, the argv as the command. A cloud
// checkout from before B20 has no job-runs.ts and writes none.
const jobRunsFile = join(repo, "src/reconciler/job-runs.ts");
if (await Bun.file(jobRunsFile).exists()) {
	const { oneOffJob } = await import(migrateJobFile);
	const runs = await import(jobRunsFile);
	const { APP_EPHEMERAL } = await import(join(repo, "src/lib/plan.ts"));
	const runId = "7a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d";
	const job = oneOffJob({
		namespace: rendered.namespace,
		project: rendered.tfvarsJson.project,
		app: "menu",
		name: runs.jobRunName("menu", runId),
		component: runs.JOB_COMPONENT,
		container: "job",
		vars: rendered.tfvarsJson.apps.menu,
		image: MENU_IMAGE,
		command: ["sh", "-c", "exit 7"],
		args: [],
		extraEnv: [
			{
				name: "CLOUD_DATABASE_POOL_SIZE",
				value: String(runs.JOB_DATABASE_CONNECTIONS),
			},
		],
		labels: { "cloud.viktorbarzin.me/job": runId },
		appPort: fixtures.INSTANCE.appPort,
		ephemeral: APP_EPHEMERAL,
		activeDeadlineSeconds: runs.JOB_ACTIVE_DEADLINE_SECONDS,
		ttlSecondsAfterFinished: runs.JOB_RUN_TTL_SECONDS,
	});
	await writeFile(join(out, "one-off-job.json"), JSON.stringify(job, null, 2));
}

// The psql toolbox of a session on the Postgres (B22), built by Cloud's own
// code with the image Cloud pins. A cloud checkout from before B22 has no
// toolbox.ts and writes none.
const toolboxFile = join(repo, "src/reconciler/toolbox.ts");
if (await Bun.file(toolboxFile).exists()) {
	const { toolboxJob } = await import(toolboxFile);
	const [postgres] = Object.keys(rendered.tfvarsJson.postgres);
	const job = toolboxJob({
		project: rendered.tfvarsJson.project,
		sessionId: "5c4d3e2f-1a0b-4c9d-8e7f-6a5b4c3d2e1f",
		target: "postgres",
		service: postgres,
		image: renderer.TOOLBOX_IMAGES.postgres,
	});
	await writeFile(join(out, "toolbox-job.json"), JSON.stringify(job, null, 2));
}

// The Postgres task Jobs (B28b, B28c), each with its credentials Secret,
// built by Cloud's own code in namespace cloud. A cloud checkout from
// before B28 has no pg-task-jobs.ts and writes none.
const pgTaskFile = join(repo, "src/reconciler/pg-task-jobs.ts");
if (await Bun.file(pgTaskFile).exists()) {
	const tasks = await import(pgTaskFile);
	const taskId = "5c4b3a29-1807-4f6e-9d5c-4b3a29180765";
	const database = renderer.postgresRoleName(rendered.tfvarsJson.project, "db");
	const b64 = (v: string) => Buffer.from(v).toString("base64");
	const found: Record<string, unknown> = { image: tasks.PG_TASK_IMAGE };
	for (const kind of ["backups", "backup", "export", "restore"]) {
		const job = tasks.pgTaskJob({
			namespace: "cloud",
			taskId,
			kind,
			project: rendered.tfvarsJson.project,
			database,
			...(kind === "restore" ? { file: "dump_2026_11_19_00_00.dump" } : {}),
		});
		const secret = tasks.connects(kind)
			? tasks.pgTaskSecret({
					namespace: "cloud",
					taskId,
					kind,
					job: {
						name: job.metadata.name,
						uid: "00000000-0000-4000-8000-000000000030",
					},
					credentials: {
						host: b64("pg-cluster-rw.dbaas"),
						port: b64("5432"),
						database: b64(database),
						username: b64(database),
						password: b64("not-a-real-password"),
					},
					...(kind === "export" ? { exportToken: "t".repeat(64) } : {}),
				})
			: null;
		found[kind] = { job, secret };
	}
	await writeFile(join(out, "pg-tasks.json"), JSON.stringify(found, null, 2));
}

const list: { dir: string; name: string; namespace: string }[] = [];
for (const [i, [name, projectFile]] of Object.entries(
	fixtures.FIXTURES as Record<string, unknown>,
).entries()) {
	const dir = join("fixtures", String(i));
	const r = await writeRoot(join(out, dir), projectFile);
	list.push({ dir, name, namespace: r.namespace });
}
await writeFile(join(out, "fixtures.json"), JSON.stringify(list, null, 2));
await writeFile(
	join(out, "contract.json"),
	JSON.stringify(
		{
			namespace: rendered.namespace,
			images: renderer.IMAGES,
			// Null before B22.
			toolboxImages: renderer.TOOLBOX_IMAGES ?? null,
			egressExcluded: renderer.EGRESS_EXCLUDED,
			egressDeniedTcpPorts: renderer.EGRESS_DENIED_TCP_PORTS ?? null,
			stripCookies: fixtures.INSTANCE.stripCookies,
			appPort: fixtures.INSTANCE.appPort,
			authentik: fixtures.INSTANCE.authentik,
			// What every edge Service names unless an Operator sets
			// EDGE_SERVERS_TRANSPORT; null before Cloud had it.
			edgeServersTransport:
				appConfig.app.reconciler.edgeServersTransport ?? null,
			apps: Object.keys(rendered.tfvarsJson.apps),
			postgres: Object.keys(rendered.tfvarsJson.postgres),
		},
		null,
		2,
	),
);
