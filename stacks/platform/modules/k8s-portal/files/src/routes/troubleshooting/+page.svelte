<main class="content">
	<h1>Troubleshooting</h1>

	<section>
		<h2>"kubectl can't connect to the server"</h2>
		<ol>
			<li>Check your VPN: <code>tailscale status</code> — should show "connected"</li>
			<li>Check KUBECONFIG: <code>echo $KUBECONFIG</code> — should be <code>~/.kube/config-home</code></li>
			<li>Test connectivity: <code>ping 10.0.20.100</code></li>
			<li>If ping works but kubectl doesn't, re-run the <a href="/setup">setup script</a></li>
		</ol>
	</section>

	<section>
		<h2>"Forbidden" or "Permission denied"</h2>
		<p>You may not have access to that namespace. Your access is scoped to specific namespaces.</p>
		<p>Try: <code>kubectl get namespaces</code> to see which namespaces you can access.</p>
		<p>Need access to another namespace? Ask Viktor.</p>
	</section>

	<section>
		<h2>"Pod is CrashLoopBackOff"</h2>
		<ol>
			<li>Check pod logs: <code>kubectl logs -n &lt;namespace&gt; &lt;pod-name&gt; --tail=50</code></li>
			<li>Check previous crash: <code>kubectl logs -n &lt;namespace&gt; &lt;pod-name&gt; --previous</code></li>
			<li>Check events: <code>kubectl describe pod -n &lt;namespace&gt; &lt;pod-name&gt;</code></li>
			<li>Common causes: OOMKilled (need more memory), bad config, database connection failure</li>
		</ol>
	</section>

	<section>
		<h2>"PR CI failed"</h2>
		<ol>
			<li>Check the Woodpecker CI dashboard: <a href="https://ci.viktorbarzin.me">ci.viktorbarzin.me</a></li>
			<li>Read the build logs — the error is usually at the bottom</li>
			<li>Fix the issue, commit, and push — CI will re-run</li>
		</ol>
	</section>

	<section>
		<h2>"I need a new secret / database password"</h2>
		<p>Secrets are managed by Viktor in an encrypted file. You cannot add them yourself.</p>
		<ol>
			<li>Comment on your PR: "Need DB password for &lt;service&gt;"</li>
			<li>Viktor adds the secret and pushes to your branch</li>
			<li>Reference it as <code>var.&lt;service&gt;_db_password</code> in your Terraform</li>
		</ol>
	</section>

	<section>
		<h2>Still stuck?</h2>
		<p>Email Viktor at <a href="mailto:vbarzin@gmail.com">vbarzin@gmail.com</a> or message on Slack.</p>
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
