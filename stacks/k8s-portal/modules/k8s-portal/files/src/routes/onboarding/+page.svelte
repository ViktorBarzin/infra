<script>
	import { page } from '$app/stores';
	let showNamespaceOwner = $derived($page.url.searchParams.get('role') === 'namespace-owner');
</script>

<main class="content">
	<h1>Getting Started</h1>
	<p>
		Welcome! There are three ways to reach the home Kubernetes cluster. Pick the one that fits —
		the first two need <strong>zero setup</strong> and open right in your browser.
	</p>

	<section>
		<h2>Three ways in</h2>
		<table>
			<thead><tr><th>Path</th><th>Best for</th><th>Setup</th></tr></thead>
			<tbody>
				<tr>
					<td><a href="#path-terminal"><strong>A — Web terminal</strong></a></td>
					<td>Just want to start working now</td>
					<td>None — opens in your browser</td>
				</tr>
				<tr>
					<td><a href="#path-dashboard"><strong>B — Web dashboard</strong></a></td>
					<td>Click around, watch your app, read logs</td>
					<td>None — opens in your browser</td>
				</tr>
				<tr>
					<td><a href="#path-laptop"><strong>C — Your own machine</strong></a></td>
					<td>kubectl / Terraform locally, full control</td>
					<td>VPN + one-line installer</td>
				</tr>
			</tbody>
		</table>
		<div class="callout info">
			<strong>Not sure?</strong> Start with the <a href="#path-terminal">web terminal (Path A)</a>.
			Everything is already installed and your repos are already cloned — you can run your first
			<code>kubectl</code> command within a minute, from any device.
		</div>
	</section>

	<section id="path-terminal" class="path">
		<h2>Path A — Web terminal <span class="badge rec">Recommended</span> <span class="badge none">No setup</span></h2>
		<p>
			A full terminal that runs in your browser — nothing to install, works from any device
			(even a tablet). It drops you into your own account on the shared workstation, with every
			tool already set up.
		</p>
		<ol>
			<li>Open <a href="https://t3.viktorbarzin.me" target="_blank">t3.viktorbarzin.me</a></li>
			<li>Sign in with your Authentik account (the same SSO login as this portal)</li>
			<li>You land in a ready-to-use shell. Try it:
				<pre>kubectl get pods -n YOUR_NAMESPACE</pre>
			</li>
		</ol>
		<div class="callout info">
			<strong>Already done for you</strong> on the workstation:
			<ul>
				<li><code>kubectl</code> + your kubeconfig, scoped to your namespaces (no login dance)</li>
				<li><code>vault</code>, <code>terragrunt</code>, <code>terraform</code>, <code>sops</code>, <code>kubeseal</code></li>
				<li>Your repos cloned under <code>~/code</code> — the <code>infra</code> repo plus your own project repos</li>
				<li>Claude Code, ready to pair with you on changes</li>
			</ul>
		</div>
		<div class="callout warning">
			<strong>No access yet?</strong> The workstation is provisioned per person. If
			<code>t3.viktorbarzin.me</code> says you're not authorized, ask Viktor to add you
			(<a href="mailto:vbarzin@gmail.com">vbarzin@gmail.com</a> or Slack).
		</div>
	</section>

	<section id="path-dashboard" class="path">
		<h2>Path B — Web dashboard <span class="badge none">No setup</span></h2>
		<p>
			A point-and-click view of the cluster — browse your pods, read logs, restart a deployment,
			check events. Nothing to install.
		</p>
		<ol>
			<li>Open <a href="https://k8s.viktorbarzin.me" target="_blank">k8s.viktorbarzin.me</a></li>
			<li>Sign in with your Authentik account</li>
			<li>
				You're dropped straight into the Kubernetes Dashboard, already authenticated as you —
				<strong>no token to paste</strong>. The portal injects your personal access token for you.
			</li>
		</ol>
		<div class="callout info">
			Scoped to your namespace(s): you can see and manage your own workloads, but not other
			tenants'. This path uses a per-user token that does <em>not</em> depend on CLI login, so it
			keeps working even if <code>kubectl</code> OIDC login is having a bad day — making it the
			reliable fallback for Path C.
		</div>
	</section>

	<section id="path-laptop" class="path c">
		<h2>Path C — From your own machine</h2>
		<p>
			For running <code>kubectl</code>, <code>vault</code> and Terraform locally. This is the most
			powerful path and the one to use for infrastructure changes — it just needs a bit more setup
			because the cluster API lives on a private network.
		</p>

		<div class="role-tabs">
			<a href="/onboarding?role=general#path-laptop" class:active={!showNamespaceOwner}>General User</a>
			<a href="/onboarding?role=namespace-owner#path-laptop" class:active={showNamespaceOwner}>Namespace Owner</a>
		</div>
		<p class="prereq">
			{#if showNamespaceOwner}
				Namespace owner — you'll also set up Vault and encrypted Terraform state so you can deploy
				your own app stacks.
			{:else}
				General user — VPN, kubectl and git access. (Managing your own app stack? Switch to the
				<strong>Namespace Owner</strong> tab above.)
			{/if}
		</p>

		<section>
			<h3>Step 1 — Join the VPN</h3>
			<p>The cluster API is on a private network (<code>10.0.20.0/24</code>), so you need VPN access first.</p>
			<ol>
				<li>Install <a href="https://tailscale.com/download" target="_blank">Tailscale</a> for your OS</li>
				<li>Run this in your terminal:
					<pre>tailscale login --login-server https://headscale.viktorbarzin.me</pre>
				</li>
				<li>A browser window opens with a registration URL</li>
				<li>Send that URL to Viktor via email (<a href="mailto:vbarzin@gmail.com">vbarzin@gmail.com</a>) or Slack</li>
				<li>Wait for approval (usually within a few hours)</li>
				<li>Once approved, test: <pre>ping 10.0.20.100</pre></li>
			</ol>
		</section>

		<section>
			<h3>Step 2 — Install the tools</h3>
			<p>Run one of these to install everything automatically (kubectl, kubelogin, vault, terragrunt, terraform, kubeseal) and write your kubeconfig to <code>~/.kube/config-home</code>:</p>
			<h4>macOS</h4>
			<p class="prereq">Requires <a href="https://brew.sh" target="_blank">Homebrew</a>. Install it first if you don't have it.</p>
			<pre>bash &lt;(curl -fsSL https://k8s-portal.viktorbarzin.me/setup/script?os=mac)</pre>
			<h4>Linux</h4>
			<pre>bash &lt;(curl -fsSL https://k8s-portal.viktorbarzin.me/setup/script?os=linux)</pre>
			<h4>Windows</h4>
			<p>Use <a href="https://learn.microsoft.com/en-us/windows/wsl/install" target="_blank">WSL2</a> and follow the Linux instructions.</p>
		</section>

		<section>
			<h3>Step 3 — Verify access</h3>
			<p>Run this. The first time, it opens your browser for SSO login:</p>
			<pre>kubectl get {showNamespaceOwner ? 'pods -n YOUR_NAMESPACE' : 'namespaces'}</pre>
			<p>You should see your resources (or an empty list if you haven't deployed anything yet).</p>
			<div class="callout warning">
				<strong>Browser login loops, or kubectl says "Unauthorized"?</strong> Command-line SSO
				(OIDC) can occasionally be unavailable. When that happens, use the
				<a href="#path-dashboard">web dashboard (Path B)</a> or the
				<a href="#path-terminal">web terminal (Path A)</a> — both authenticate a different way and
				keep working — and let Viktor know.
			</div>
			<p class="prereq">Connection error instead? Make sure the VPN is up: <code>tailscale status</code>.</p>
		</section>

		{#if showNamespaceOwner}
			<section>
				<h3>Step 4 — Log into Vault</h3>
				<p>Vault manages your secrets and issues dynamic Kubernetes credentials.</p>
				<pre>vault login -method=oidc</pre>
				<p>This opens your browser for Authentik SSO. After login, your token is saved to <code>~/.vault-token</code>.</p>
			</section>

			<section>
				<h3>Step 5 — Clone the infra repo</h3>
				<pre>git clone https://github.com/ViktorBarzin/infra.git
cd infra</pre>
				<p>This is where all the infrastructure configuration lives. Terraform state is committed as encrypted files.</p>
			</section>

			<section>
				<h3>Step 6 — Decrypt your state</h3>
				<p>Terraform state is encrypted with SOPS. Your Vault login gives you access to <strong>only your stacks</strong>.</p>
				<pre># Make sure you're logged into Vault
vault login -method=oidc

# Decrypt your stack's state
scripts/state-sync decrypt YOUR_NAMESPACE

# Plan changes (auto-decrypts before, auto-encrypts after)
cd stacks/YOUR_NAMESPACE
../../scripts/tg plan</pre>

				<div class="diagram">
					<h3>How state encryption works</h3>
					<div class="flow-diagram">
						<div class="flow-row">
							<div class="flow-box accent">vault login -method=oidc</div>
							<div class="flow-arrow">→</div>
							<div class="flow-box">Authentik SSO</div>
							<div class="flow-arrow">→</div>
							<div class="flow-box accent">~/.vault-token</div>
						</div>
						<div class="flow-separator">↓</div>
						<div class="flow-row">
							<div class="flow-box accent">scripts/tg plan</div>
							<div class="flow-arrow">→</div>
							<div class="flow-box">state-sync decrypt</div>
							<div class="flow-arrow">→</div>
							<div class="flow-box">Vault Transit<br/><small>sops-state-YOUR_NS</small></div>
						</div>
						<div class="flow-separator">↓</div>
						<div class="flow-row">
							<div class="flow-box">terragrunt plan/apply</div>
							<div class="flow-arrow">→</div>
							<div class="flow-box">state-sync encrypt</div>
							<div class="flow-arrow">→</div>
							<div class="flow-box accent">git commit + push</div>
						</div>
					</div>
				</div>

				<div class="callout info">
					<strong>Access control:</strong> You can only decrypt state for your own namespaces.
					Each namespace has its own Vault Transit encryption key. Your Vault policy
					(<code>sops-user-YOUR_USERNAME</code>) only grants access to your keys.
				</div>
			</section>

			<section>
				<h3>Step 7 — Create your first app stack</h3>
				<ol>
					<li>Copy the template: <pre>cp -r stacks/_template stacks/myapp
mv stacks/myapp/main.tf.example stacks/myapp/main.tf</pre></li>
					<li>Edit <code>stacks/myapp/main.tf</code> — replace all <code>&lt;placeholders&gt;</code></li>
					<li>Store secrets in Vault:
						<pre>vault kv put secret/YOUR_USERNAME/myapp DB_PASSWORD=secret123</pre>
					</li>
					<li>Apply your stack:
						<pre>cd stacks/myapp && ../../scripts/tg apply</pre>
					</li>
					<li>Commit encrypted state:
						<pre>cd ../..
git add stacks/myapp/ state/stacks/myapp/terraform.tfstate.enc
git commit -m "add myapp stack"
git push</pre>
					</li>
				</ol>
			</section>

			<section>
				<h3>Architecture Overview</h3>
				<p>Here's how your changes flow through the system:</p>

				<div class="diagram">
					<h3>Apply workflow</h3>
					<div class="arch-grid">
						<div class="arch-col">
							<div class="arch-header">Your Machine</div>
							<div class="arch-box">git pull</div>
							<div class="arch-arrow">↓</div>
							<div class="arch-box">scripts/tg plan</div>
							<div class="arch-arrow">↓ <small>auto-decrypt</small></div>
							<div class="arch-box">scripts/tg apply</div>
							<div class="arch-arrow">↓ <small>auto-encrypt</small></div>
							<div class="arch-box">git push</div>
						</div>
						<div class="arch-col">
							<div class="arch-header">Vault</div>
							<div class="arch-box small">OIDC auth<br/><small>Authentik SSO</small></div>
							<div class="arch-arrow">↓</div>
							<div class="arch-box small">Transit decrypt<br/><small>sops-state-*</small></div>
							<div class="arch-arrow">↓</div>
							<div class="arch-box small">Transit encrypt<br/><small>per-stack key</small></div>
						</div>
						<div class="arch-col">
							<div class="arch-header">Cluster</div>
							<div class="arch-box small">K8s API</div>
							<div class="arch-arrow">↓</div>
							<div class="arch-box small">Your namespace<br/><small>pods, services</small></div>
							<div class="arch-arrow">↓</div>
							<div class="arch-box small">Traefik ingress<br/><small>*.viktorbarzin.me</small></div>
						</div>
					</div>
				</div>

				<div class="diagram">
					<h3>Security model</h3>
					<table>
						<thead><tr><th>Layer</th><th>What</th><th>How</th></tr></thead>
						<tbody>
						<tr><td>Authentication</td><td>Who are you?</td><td>Authentik SSO (OIDC) → Vault token</td></tr>
						<tr><td>Authorization</td><td>What can you access?</td><td>Vault policy (<code>sops-user-*</code>) scoped to your namespaces</td></tr>
						<tr><td>Encryption at rest</td><td>State in git</td><td>SOPS + Vault Transit (per-stack key)</td></tr>
						<tr><td>Encryption fallback</td><td>Bootstrap / DR</td><td>age keys (admin only)</td></tr>
						<tr><td>Network</td><td>Cluster access</td><td>Headscale VPN (private 10.0.20.0/24)</td></tr>
						</tbody>
					</table>
				</div>
			</section>
		{:else}
			<section>
				<h3>Step 4 — Clone the repo</h3>
				<pre>git clone https://github.com/ViktorBarzin/infra.git
cd infra</pre>
				<p>This is where all the infrastructure configuration lives.</p>
			</section>

			<section>
				<h3>Step 5 — Your first change</h3>
				<ol>
					<li>Create a branch: <pre>git checkout -b my-first-change</pre></li>
					<li>Edit a service file (e.g., change an image tag in <code>stacks/echo/main.tf</code>)</li>
					<li>Commit and push: <pre>git add . &amp;&amp; git commit -m "my first change" &amp;&amp; git push -u origin my-first-change</pre></li>
					<li>Open a Pull Request on GitHub</li>
					<li>Viktor reviews and merges</li>
					<li>Woodpecker CI automatically applies the change to the cluster</li>
					<li>Slack notification confirms it worked</li>
				</ol>
			</section>
		{/if}
	</section>
</main>

<style>
	.content { max-width: 768px; margin: 2rem auto; padding: 0 1rem; font-family: system-ui, -apple-system, sans-serif; line-height: 1.6; }
	.content h1 { border-bottom: 1px solid #e0e0e0; padding-bottom: 0.5rem; }
	.content h2 { margin-top: 2rem; color: #333; }
	.content h3 { color: #444; margin: 1.25rem 0 0.25rem; }
	.content h4 { color: #666; margin: 0.75rem 0 0.25rem; }
	.content pre { background: #1e1e1e; color: #d4d4d4; padding: 1rem; border-radius: 6px; overflow-x: auto; }
	.content code { background: #f0f0f0; padding: 2px 6px; border-radius: 3px; }
	.content .prereq { font-size: 0.9rem; color: #666; font-style: italic; }
	section { margin: 2rem 0; }
	section section { margin: 1.25rem 0; }

	.path { border-left: 4px solid #4fc3f7; padding-left: 1.25rem; scroll-margin-top: 4rem; }
	.path.c { border-left-color: #bbb; }

	.badge { display: inline-block; font-size: 0.65rem; font-weight: 700; text-transform: uppercase; letter-spacing: 0.5px; padding: 0.15rem 0.5rem; border-radius: 4px; vertical-align: middle; margin-left: 0.4rem; }
	.badge.rec { background: #d4f8d4; color: #1b5e20; }
	.badge.none { background: #e3f2fd; color: #0d47a1; }

	.role-tabs { display: flex; gap: 0; margin: 1.5rem 0 0.5rem; border-bottom: 2px solid #e0e0e0; }
	.role-tabs a { padding: 0.5rem 1.5rem; text-decoration: none; color: #666; border-bottom: 2px solid transparent; margin-bottom: -2px; }
	.role-tabs a.active { color: #333; border-bottom-color: #333; font-weight: 600; }
	table { border-collapse: collapse; width: 100%; margin: 0.5rem 0; }
	th, td { border: 1px solid #ddd; padding: 0.5rem; text-align: left; }
	th { background: #f5f5f5; }

	.callout { padding: 1rem; border-radius: 6px; margin: 1rem 0; }
	.callout.info { background: #e8f4fd; border-left: 4px solid #2196f3; }
	.callout.warning { background: #fff3cd; border-left: 4px solid #ffc107; }
	.callout ul { margin: 0.5rem 0 0; padding-left: 1.25rem; }

	.diagram { background: #fafafa; border: 1px solid #e0e0e0; border-radius: 8px; padding: 1.5rem; margin: 1.5rem 0; }
	.diagram h3 { margin: 0 0 1rem 0; color: #333; font-size: 0.95rem; text-transform: uppercase; letter-spacing: 0.5px; }

	.flow-diagram { display: flex; flex-direction: column; align-items: center; gap: 0.25rem; }
	.flow-row { display: flex; align-items: center; gap: 0.5rem; flex-wrap: wrap; justify-content: center; }
	.flow-box { background: white; border: 2px solid #ddd; border-radius: 6px; padding: 0.5rem 1rem; font-family: monospace; font-size: 0.85rem; text-align: center; }
	.flow-box.accent { border-color: #333; font-weight: 600; }
	.flow-box small { display: block; color: #888; font-weight: normal; }
	.flow-arrow { color: #999; font-size: 1.2rem; }
	.flow-separator { color: #999; font-size: 1.2rem; }

	.arch-grid { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 1.5rem; }
	.arch-col { display: flex; flex-direction: column; align-items: center; gap: 0.25rem; }
	.arch-header { font-weight: 700; font-size: 0.85rem; text-transform: uppercase; letter-spacing: 0.5px; color: #555; margin-bottom: 0.5rem; padding: 0.25rem 0.75rem; background: #e8e8e8; border-radius: 4px; }
	.arch-box { background: white; border: 2px solid #ddd; border-radius: 6px; padding: 0.5rem 0.75rem; font-family: monospace; font-size: 0.8rem; text-align: center; width: 100%; box-sizing: border-box; }
	.arch-box.small { font-size: 0.75rem; }
	.arch-box small { display: block; color: #888; font-family: monospace; }
	.arch-arrow { color: #999; font-size: 1rem; }

	@media (max-width: 600px) {
		.arch-grid { grid-template-columns: 1fr; }
		.flow-row { flex-direction: column; }
		.flow-arrow { transform: rotate(90deg); }
	}
</style>
