<script lang="ts">
	let { data } = $props();
</script>

<main>
	<h1>Kubernetes Access Portal</h1>

	<section>
		<h2>Your Identity</h2>
		<p><strong>Username:</strong> {data.username}</p>
		<p><strong>Email:</strong> {data.email}</p>
		<p><strong>Role:</strong> {data.role}</p>
		{#if data.namespaces.length > 0}
			<p><strong>Namespaces:</strong> {data.namespaces.join(', ')}</p>
		{/if}
	</section>

	<section>
		<h2>Get Started</h2>
		<ol>
			<li><a href="/setup">Install kubectl and kubelogin</a></li>
			<li><a href="/download">Download your kubeconfig</a></li>
			<li>Run <code>kubectl get pods</code> to verify access</li>
		</ol>
	</section>
</main>

<style>
	main {
		max-width: 640px;
		margin: 2rem auto;
		font-family: system-ui;
	}
	code {
		background: #f0f0f0;
		padding: 2px 6px;
		border-radius: 3px;
	}
	section {
		margin: 2rem 0;
	}
</style>
