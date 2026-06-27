<script lang="ts">
	let { data } = $props();
</script>

<main>
	<h1>Kubernetes Access Portal</h1>

	<div class="callout info">
		<strong>Fastest way in:</strong> open the <a href="https://t3.viktorbarzin.me">web terminal</a> or the
		<a href="https://k8s.viktorbarzin.me">dashboard</a> and sign in — no install, no VPN needed. Prefer your
		own machine? The <a href="/onboarding#path-laptop">local-setup guide</a> covers VPN + kubectl, and the
		<a href="/onboarding">Getting Started page</a> compares all three access paths.
	</div>

	<section>
		<h2>Your Identity</h2>
		<p><strong>Username:</strong> {data.username}</p>
		<p><strong>Email:</strong> {data.email}</p>
		<p><strong>Role:</strong> {data.role}</p>
		{#if data.namespaces.length > 0}
			<p><strong>Namespaces:</strong> {data.namespaces.join(', ')}</p>
		{/if}
	</section>

	{#if data.role === 'namespace-owner'}
		<section>
			<h2>Your Namespace</h2>
			<p><strong>Assigned namespaces:</strong> {data.namespaces.join(', ')}</p>

			<h3>Quick Commands</h3>
			<p>Run these as-is in the <a href="https://t3.viktorbarzin.me">web terminal</a> — it's already signed in as you.</p>
			<pre>
# Check your pods
kubectl get pods -n {data.namespaces[0]}

# View quota usage
kubectl describe resourcequota -n {data.namespaces[0]}

# Log into Vault
vault login -method=oidc

# Store a secret
vault kv put secret/{data.username}/myapp KEY=value

# Get K8s deploy token
vault write kubernetes/creds/{data.namespaces[0]}-deployer \
  kubernetes_namespace={data.namespaces[0]}</pre>
		</section>
	{/if}

	<section>
		<h2>Get Started</h2>
		<h3>No setup — start now</h3>
		<ol>
			<li><a href="https://t3.viktorbarzin.me">Open the web terminal</a> — a ready shell with kubectl, Vault and your repos already set up</li>
			<li><a href="https://k8s.viktorbarzin.me">Open the dashboard</a> — point-and-click view of your workloads</li>
		</ol>
		<h3>On your own machine</h3>
		<ol>
			{#if data.role === 'namespace-owner'}
				<li><a href="/onboarding?role=namespace-owner#path-laptop">Follow the namespace-owner setup</a> (VPN, kubectl, Vault, encrypted state)</li>
			{:else}
				<li><a href="/onboarding#path-laptop">Follow the local setup</a> (VPN, kubectl, git)</li>
			{/if}
			<li><a href="/setup">Install kubectl and kubelogin</a></li>
			<li><a href="/download">Download your kubeconfig</a></li>
			<li>Run <code>kubectl get namespaces</code> to verify access</li>
		</ol>
		<p><a href="/onboarding">Compare all three access paths →</a></p>
	</section>

	<section>
		<h2>Resources</h2>
		<ul>
			<li><a href="/architecture">Architecture overview</a></li>
			<li><a href="/services">Service catalog</a></li>
			<li><a href="/contributing">How to contribute</a></li>
			<li><a href="/troubleshooting">Troubleshooting</a></li>
		</ul>
	</section>
</main>

<style>
	main {
		max-width: 768px;
		margin: 2rem auto;
		padding: 0 1rem;
		font-family: system-ui, -apple-system, sans-serif;
		line-height: 1.6;
	}
	code {
		background: #f0f0f0;
		padding: 2px 6px;
		border-radius: 3px;
	}
	section {
		margin: 2rem 0;
	}
	.callout {
		padding: 1rem;
		border-radius: 6px;
		margin: 1rem 0;
	}
	.callout.info {
		background: #e8f4fd;
		border-left: 4px solid #2196f3;
	}
	.callout a {
		color: #0d47a1;
		font-weight: 600;
	}
</style>
