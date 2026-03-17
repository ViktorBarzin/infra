<script lang="ts">
	let { data } = $props();
</script>

<main>
	<h1>Kubernetes Access Portal</h1>

	<div class="callout warning">
		<strong>VPN Required</strong> — The cluster is on a private network. You need Headscale VPN access before kubectl will work.
		<a href="/onboarding">See the Getting Started guide</a> for VPN setup instructions.
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
		<ol>
			{#if data.role === 'namespace-owner'}
				<li><a href="/onboarding?role=namespace-owner">Complete the namespace-owner onboarding guide</a></li>
			{:else}
				<li><a href="/onboarding">Complete the onboarding guide</a> (VPN, kubectl, git)</li>
			{/if}
			<li><a href="/setup">Install kubectl and kubelogin</a></li>
			<li><a href="/download">Download your kubeconfig</a></li>
			<li>Run <code>kubectl get namespaces</code> to verify access</li>
		</ol>
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
	.callout.warning {
		background: #fff3cd;
		border-left: 4px solid #ffc107;
	}
	.callout a {
		color: #856404;
		font-weight: 600;
	}
</style>
