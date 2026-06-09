<main class="content">
	<h1>Agent Bootstrap</h1>
	<p>Point any AI coding agent at this cluster and it can bootstrap itself automatically.</p>

	<section>
		<h2>For AI Agents</h2>
		<p>Fetch the machine-readable bootstrap document:</p>
		<pre>curl -fsSL https://k8s-portal.viktorbarzin.me/agent</pre>
		<p>This returns a plain-text markdown document with everything an agent needs: setup commands, critical rules, secrets workflow, Terraform conventions, key file paths, and common operations.</p>
	</section>

	<section>
		<h2>Usage with Claude Code</h2>
		<pre>claude "$(curl -fsSL https://k8s-portal.viktorbarzin.me/agent)" "Deploy a new echo service"</pre>
		<p>Or within a session:</p>
		<ol>
			<li>Clone the repo: <code>git clone https://github.com/ViktorBarzin/infra.git && cd infra</code></li>
			<li>Start Claude Code: <code>claude</code></li>
			<li>Claude auto-reads <code>AGENTS.md</code> and <code>.claude/CLAUDE.md</code> from the repo</li>
		</ol>
	</section>

	<section>
		<h2>Usage with Codex / Other Agents</h2>
		<ol>
			<li>Clone the repo and <code>cd</code> into it</li>
			<li>Run the setup script: <code>bash &lt;(curl -fsSL https://k8s-portal.viktorbarzin.me/setup/script?os=linux)</code></li>
			<li>Start the agent — it will read <code>AGENTS.md</code> for instructions</li>
		</ol>
		<p>If the agent doesn't auto-read <code>AGENTS.md</code>, feed it the bootstrap doc:</p>
		<pre>curl -fsSL https://k8s-portal.viktorbarzin.me/agent</pre>
	</section>

	<section>
		<h2>What the Agent Gets</h2>
		<ul>
			<li>Quick-start commands (setup script, repo clone)</li>
			<li>Critical rules (no kubectl apply, no plaintext secrets, no NFS restart)</li>
			<li>Sealed Secrets workflow (kubeseal self-service)</li>
			<li>Terraform conventions (fileset pattern, tiers, storage, shared vars)</li>
			<li>Key file paths in the repo</li>
			<li>Common operations (deploy, fix pods, add secrets)</li>
			<li>Contributing workflow (branch, PR, review, CI)</li>
		</ul>
	</section>

	<section>
		<h2>The <code>/agent</code> Endpoint</h2>
		<p>The endpoint is <strong>unauthenticated</strong> — no login required. Agents can <code>curl</code> or <code>WebFetch</code> it directly without a browser session, just like the setup script.</p>
		<p>Content-Type: <code>text/plain</code> — no HTML parsing needed.</p>
	</section>
</main>

<style>
	.content { max-width: 768px; margin: 2rem auto; padding: 0 1rem; font-family: system-ui, -apple-system, sans-serif; line-height: 1.6; }
	.content h1 { border-bottom: 1px solid #e0e0e0; padding-bottom: 0.5rem; }
	.content h2 { margin-top: 2rem; color: #333; }
	.content pre { background: #1e1e1e; color: #d4d4d4; padding: 1rem; border-radius: 6px; overflow-x: auto; }
	.content code { background: #f0f0f0; padding: 2px 6px; border-radius: 3px; }
	section { margin: 2rem 0; }
</style>
