<main class="content">
	<h1>Getting Started</h1>
	<p>Welcome! Follow these steps to get access to the home Kubernetes cluster.</p>

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
</style>
