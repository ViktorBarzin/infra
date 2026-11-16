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
 *                          strip list, the Authentik slug and the namespace
 *
 *   migrate-job.json       the migrate Job Cloud starts for a Deploy of the
 *                          public App (src/reconciler/migrate-job.ts, B16)
 *   fixtures/<n>/          the same two files for each of Cloud's snapshot
 *                          fixtures (render.fixtures.ts FIXTURES), and
 *   fixtures.json          [{dir, name, namespace}] listing them in order
 *
 * The combined Project holds a private App, a public App connected to a
 * Postgres Service and to an internal App (with a built image, a migrate
 * init container and HTTP health check probes), the internal App (no edge,
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
			egressExcluded: renderer.EGRESS_EXCLUDED,
			egressDeniedTcpPorts: renderer.EGRESS_DENIED_TCP_PORTS ?? null,
			stripCookies: fixtures.INSTANCE.stripCookies,
			appPort: fixtures.INSTANCE.appPort,
			authentik: fixtures.INSTANCE.authentik,
			apps: Object.keys(rendered.tfvarsJson.apps),
			postgres: Object.keys(rendered.tfvarsJson.postgres),
		},
		null,
		2,
	),
);
