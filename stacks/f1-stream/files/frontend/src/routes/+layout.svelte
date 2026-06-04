<script>
	import '../app.css';

	let { children } = $props();
</script>

<div class="min-h-screen flex flex-col">
	<header class="border-b border-f1-border bg-f1-surface">
		<nav class="max-w-6xl mx-auto px-4 py-3 flex items-center gap-6">
			<a href="/" class="flex items-center gap-2 text-lg font-bold text-white hover:text-f1-red transition-colors">
				<span class="text-f1-red font-black text-xl">F1</span>
				<span>Stream</span>
			</a>
			<div class="flex gap-4 text-sm">
				<a href="/" class="text-f1-text-muted hover:text-white transition-colors">Schedule</a>
				<a href="/watch" class="text-f1-text-muted hover:text-white transition-colors">Watch</a>
			</div>
		</nav>
	</header>

	<main class="flex-1">
		{@render children()}
	</main>

	<footer class="border-t border-f1-border py-3 text-center text-xs text-f1-text-muted">
		F1 Stream
	</footer>
</div>
