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
 * The Project holds a private App, a public App connected to a Postgres
 * Service, and the Postgres Service, so every object kind Cloud renders
 * appears at least once.
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

const rendered = renderer.render(spec, fixtures.CTX);
const main = structuredClone(rendered.mainTfJson);
delete main.terraform.backend;

await mkdir(out, { recursive: true });
await writeFile(join(out, "main.tf.json"), JSON.stringify(main, null, 2));
await writeFile(
	join(out, "terraform.tfvars.json"),
	JSON.stringify(rendered.tfvarsJson, null, 2),
);
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
