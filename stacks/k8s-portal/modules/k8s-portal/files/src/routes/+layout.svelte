<script lang="ts">
	import favicon from '$lib/assets/favicon.svg';
	import { page } from '$app/stores';

	let { children } = $props();
</script>

<svelte:head>
	<link rel="icon" href={favicon} />
</svelte:head>

<nav>
	<div class="nav-inner">
		<a href="/" class="brand">K8s Portal</a>
		<div class="links">
			<a href="/onboarding" class:active={$page.url.pathname === '/onboarding'}>Getting Started</a>
			<a href="/architecture" class:active={$page.url.pathname === '/architecture'}>Architecture</a>
			<a href="/services" class:active={$page.url.pathname === '/services'}>Services</a>
			<a href="/contributing" class:active={$page.url.pathname === '/contributing'}>Contributing</a>
			<a href="/troubleshooting" class:active={$page.url.pathname === '/troubleshooting'}>Help</a>
		</div>
	</div>
</nav>

{@render children()}

<style>
	nav {
		background: #1a1a2e;
		padding: 0.75rem 1rem;
		position: sticky;
		top: 0;
		z-index: 100;
	}
	.nav-inner {
		max-width: 768px;
		margin: 0 auto;
		display: flex;
		align-items: center;
		gap: 1.5rem;
		flex-wrap: wrap;
	}
	.brand {
		color: #e0e0e0;
		text-decoration: none;
		font-weight: 700;
		font-size: 1.1rem;
	}
	.links {
		display: flex;
		gap: 1rem;
		flex-wrap: wrap;
	}
	.links a {
		color: #a0a0c0;
		text-decoration: none;
		font-size: 0.9rem;
		padding: 0.25rem 0;
	}
	.links a:hover, .links a.active {
		color: #ffffff;
		border-bottom: 2px solid #4fc3f7;
	}
</style>
