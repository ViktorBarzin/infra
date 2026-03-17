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
			<p>This is where all the infrastructure configuration lives.</p>
		</section>

		<section>
			<h2>Step 6 — Create your first app stack</h2>
			<ol>
				<li>Copy the template: <pre>cp -r stacks/_template stacks/myapp
mv stacks/myapp/main.tf.example stacks/myapp/main.tf</pre></li>
				<li>Edit <code>stacks/myapp/main.tf</code> — replace all <code>&lt;placeholders&gt;</code></li>
				<li>Store secrets in Vault:
					<pre>vault kv put secret/YOUR_USERNAME/myapp DB_PASSWORD=secret123</pre>
				</li>
				<li>Add your app domain to <code>domains</code> list in Vault KV <code>k8s_users</code></li>
				<li>Submit a PR:
					<pre>git checkout -b feat/myapp
git add stacks/myapp/
git commit -m "add myapp stack"
git push -u origin feat/myapp</pre>
				</li>
				<li>Viktor reviews and merges</li>
				<li>After merge: <code>cd stacks/myapp && terragrunt apply</code></li>
			</ol>
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
			<h2>Step 5 — Install your AI assistant (optional)</h2>
			<p>Install <a href="https://github.com/openai/codex" target="_blank">Codex CLI</a> for AI-assisted cluster management:</p>
			<pre>npm install -g @openai/codex</pre>
			<p>Codex reads the <code>AGENTS.md</code> file in the repo and knows how to work with the cluster.</p>
		</section>

		<section>
			<h2>Step 6 — Your first change</h2>
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
</style>
