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
 *   fixtures/<n>/          the same two files for each of Cloud's snapshot
 *                          fixtures (render.fixtures.ts FIXTURES), and
 *   fixtures.json          [{dir, name, namespace}] listing them in order
 *
 * The combined Project holds a private App, a public App connected to a
 * Postgres Service, and the Postgres Service, so every object kind Cloud
 * renders appears at least once; the forbidden variants are built from it.
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
		menu: fixtures.app({ access: "public", size: "nano", connects: ["db"] }),
		db: { kind: "postgres", size: "small" },
	},
};

async function writeRoot(dir: string, projectFile: unknown) {
	const r = renderer.render(projectFile, fixtures.CTX);
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

const rendered = await writeRoot(out, spec);

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
			stripCookies: fixtures.INSTANCE.stripCookies,
			authentik: fixtures.INSTANCE.authentik,
			apps: Object.keys(rendered.tfvarsJson.apps),
			postgres: Object.keys(rendered.tfvarsJson.postgres),
		},
		null,
		2,
	),
);
