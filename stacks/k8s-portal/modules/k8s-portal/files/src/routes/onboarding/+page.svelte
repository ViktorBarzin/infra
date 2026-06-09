<script>
	import { page } from '$app/stores';
	let showNamespaceOwner = $derived($page.url.searchParams.get('role') === 'namespace-owner');
</script>

<main class="content">
	<h1>Getting Started</h1>
	<p>Welcome! Follow these steps to get access to the home Kubernetes cluster.</p>

	<div class="role-tabs">
		<a href="/onboarding" class:active={!showNamespaceOwner}>General User</a>
		<a href="/onboarding?role=namespace-owner" class:active={showNamespaceOwner}>Namespace Owner</a>
	</div>

	<section>
		<h2>Step 0 — Join the VPN</h2>
		<p>The cluster is on a private network (<code>10.0.20.0/24</code>). You need VPN access first.</p>
		<ol>
			<li>Install <a href="https://tailscale.com/download" target="_blank">Tailscale</a> for your OS</li>
			<li>Run this in your terminal:
				<pre>tailscale login --login-server https://headscale.viktorbarzin.me</pre>
			</li>
			<li>A browser window will open with a registration URL</li>
			<li>Send that URL to Viktor via email (<a href="mailto:vbarzin@gmail.com">vbarzin@gmail.com</a>) or Slack</li>
			<li>Wait for approval (usually within a few hours)</li>
			<li>Once approved, test: <pre>ping 10.0.20.100</pre></li>
		</ol>
	</section>

	<section>
		<h2>Step 1 — Log in to the portal</h2>
		<p>Visit <a href="https://k8s-portal.viktorbarzin.me">k8s-portal.viktorbarzin.me</a> and sign in with your Authentik account.</p>
		<p>If you don't have an account yet, ask Viktor to create one.</p>
	</section>

	<section>
		<h2>Step 2 — Set up kubectl</h2>
		<p>Run one of these commands in your terminal to install everything automatically:</p>
		<h3>macOS</h3>
		<p class="prereq">Requires <a href="https://brew.sh" target="_blank">Homebrew</a>. Install it first if you don't have it.</p>
		<pre>bash &lt;(curl -fsSL https://k8s-portal.viktorbarzin.me/setup/script?os=mac)</pre>
		<h3>Linux</h3>
		<pre>bash &lt;(curl -fsSL https://k8s-portal.viktorbarzin.me/setup/script?os=linux)</pre>
		<h3>Windows</h3>
		<p>Use <a href="https://learn.microsoft.com/en-us/windows/wsl/install" target="_blank">WSL2</a> and follow the Linux instructions.</p>
	</section>

	{#if showNamespaceOwner}
		<section>
			<h2>Step 3 — Log into Vault</h2>
			<p>Vault manages your secrets and issues dynamic Kubernetes credentials.</p>
			<pre>vault login -method=oidc</pre>
			<p>This opens your browser for Authentik SSO. After login, your token is saved to <code>~/.vault-token</code>.</p>
		</section>

		<section>
			<h2>Step 4 — Verify kubectl access</h2>
			<p>Run this command. It will open your browser for OIDC login the first time:</p>
			<pre>kubectl get pods -n YOUR_NAMESPACE</pre>
			<p>You should see an empty list (no resources) or your running pods.</p>
		</section>

		<section>
			<h2>Step 5 — Clone the infra repo</h2>
			<pre>git clone https://github.com/ViktorBarzin/infra.git
cd infra</pre>
			<p>This is where all the infrastructure configuration lives. Terraform state is committed as encrypted files.</p>
		</section>

		<section>
			<h2>Step 6 — Install tools</h2>
			<p>You need <code>sops</code> and <code>terragrunt</code> to work with infrastructure state:</p>
			<h3>macOS</h3>
			<pre>brew install sops terragrunt</pre>
			<h3>Linux</h3>
			<pre># sops
curl -LO https://github.com/getsops/sops/releases/latest/download/sops-v3.9.4.linux.amd64
sudo mv sops-*.linux.amd64 /usr/local/bin/sops && sudo chmod +x /usr/local/bin/sops

# terragrunt
curl -LO https://github.com/gruntwork-io/terragrunt/releases/latest/download/terragrunt_linux_amd64
sudo mv terragrunt_linux_amd64 /usr/local/bin/terragrunt && sudo chmod +x /usr/local/bin/terragrunt</pre>
		</section>

		<section>
			<h2>Step 7 — Decrypt your state</h2>
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
			<h2>Step 8 — Create your first app stack</h2>
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
			<h2>Architecture Overview</h2>
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
			<h2>Step 3 — Verify access</h2>
			<p>Run this command. It will open your browser for login the first time:</p>
			<pre>kubectl get namespaces</pre>
			<p>You should see output like:</p>
			<pre class="output">NAME              STATUS   AGE
default           Active   200d
kube-system       Active   200d
monitoring        Active   200d
...</pre>
			<p>If you get a connection error, make sure your VPN is connected (<code>tailscale status</code>).</p>
		</section>

		<section>
			<h2>Step 4 — Clone the repo</h2>
			<pre>git clone https://github.com/ViktorBarzin/infra.git
cd infra</pre>
			<p>This is where all the infrastructure configuration lives.</p>
		</section>

		<section>
			<h2>Step 5 — Your first change</h2>
			<ol>
				<li>Create a branch: <pre>git checkout -b my-first-change</pre></li>
				<li>Edit a service file (e.g., change an image tag in <code>stacks/echo/main.tf</code>)</li>
				<li>Commit and push: <pre>git add . && git commit -m "my first change" && git push -u origin my-first-change</pre></li>
				<li>Open a Pull Request on GitHub</li>
				<li>Viktor reviews and merges</li>
				<li>Woodpecker CI automatically applies the change to the cluster</li>
				<li>Slack notification confirms it worked</li>
			</ol>
		</section>
	{/if}
</main>

<style>
	.content { max-width: 768px; margin: 2rem auto; padding: 0 1rem; font-family: system-ui, -apple-system, sans-serif; line-height: 1.6; }
	.content h1 { border-bottom: 1px solid #e0e0e0; padding-bottom: 0.5rem; }
	.content h2 { margin-top: 2rem; color: #333; }
	.content h3 { color: #666; margin: 1rem 0 0.25rem; }
	.content pre { background: #1e1e1e; color: #d4d4d4; padding: 1rem; border-radius: 6px; overflow-x: auto; }
	.content pre.output { background: #f5f5f5; color: #333; }
	.content code { background: #f0f0f0; padding: 2px 6px; border-radius: 3px; }
	.content .prereq { font-size: 0.9rem; color: #666; font-style: italic; }
	section { margin: 2rem 0; }
	.role-tabs { display: flex; gap: 0; margin: 1.5rem 0; border-bottom: 2px solid #e0e0e0; }
	.role-tabs a { padding: 0.5rem 1.5rem; text-decoration: none; color: #666; border-bottom: 2px solid transparent; margin-bottom: -2px; }
	.role-tabs a.active { color: #333; border-bottom-color: #333; font-weight: 600; }
	table { border-collapse: collapse; width: 100%; margin: 0.5rem 0; }
	th, td { border: 1px solid #ddd; padding: 0.5rem; text-align: left; }
	th { background: #f5f5f5; }

	.callout { padding: 1rem; border-radius: 6px; margin: 1rem 0; }
	.callout.info { background: #e8f4fd; border-left: 4px solid #2196f3; }
	.callout.warning { background: #fff3cd; border-left: 4px solid #ffc107; }

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
