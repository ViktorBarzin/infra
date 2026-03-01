<script>
	import { fetchStreams, fetchSchedule, getProxyUrl, activateStream, deactivateStream } from '$lib/api.js';
	import { onMount, onDestroy } from 'svelte';
	import { page } from '$app/state';

	// Lazy-load hls.js to code-split it into a separate chunk
	let Hls = $state(null);

	// Query params
	let sessionType = $derived(page.url?.searchParams?.get('session') || '');
	let roundNumber = $derived(page.url?.searchParams?.get('round') || '');

	// State
	let streamsData = $state(null);
	let scheduleData = $state(null);
	let loading = $state(true);
	let errorMsg = $state(null);

	// Multi-stream player state: array of active player slots
	let players = $state([]);
	const MAX_PLAYERS = 4;

	// Current session info from schedule
	let currentRace = $derived.by(() => {
		if (!scheduleData?.races || !roundNumber) return null;
		return scheduleData.races.find(r => r.round === parseInt(roundNumber));
	});

	let currentSession = $derived.by(() => {
		if (!currentRace || !sessionType) return null;
		return currentRace.sessions.find(s => s.type === sessionType);
	});

	// Layout class based on player count
	let layoutClass = $derived.by(() => {
		const count = players.length;
		if (count <= 1) return 'grid-cols-1';
		if (count === 2) return 'grid-cols-2';
		return 'grid-cols-2'; // 3-4 players: 2x2 grid
	});

	onMount(async () => {
		const hlsModule = await import('hls.js');
		Hls = hlsModule.default;
		loadData();
		document.addEventListener('fullscreenchange', onFullscreenChange);
	});

	onDestroy(() => {
		// Clean up all players
		for (const player of players) {
			cleanupPlayer(player);
		}
		if (typeof document !== 'undefined') {
			document.removeEventListener('fullscreenchange', onFullscreenChange);
		}
	});

	async function loadData() {
		loading = true;
		errorMsg = null;
		try {
			const [streamsResult, scheduleResult] = await Promise.all([
				fetchStreams(),
				fetchSchedule()
			]);
			streamsData = streamsResult;
			scheduleData = scheduleResult;
		} catch (e) {
			errorMsg = e.message;
		} finally {
			loading = false;
		}
	}

	function cleanupPlayer(player) {
		if (player.hls) {
			player.hls.destroy();
			player.hls = null;
		}
		if (player.originalUrl) {
			deactivateStream(player.originalUrl).catch(() => {});
		}
		if (player.controlsTimer) {
			clearTimeout(player.controlsTimer);
		}
	}

	function removePlayer(index) {
		const player = players[index];
		cleanupPlayer(player);
		players = players.filter((_, i) => i !== index);
	}

	function isStreamActive(url) {
		return players.some(p => p.originalUrl === url);
	}

	function playStream(stream) {
		// If already playing this stream, don't add a duplicate
		const streamUrl = stream.stream_type === 'embed' ? stream.embed_url : stream.url;
		if (isStreamActive(streamUrl)) return;

		// If at max players, replace the last one
		if (players.length >= MAX_PLAYERS) {
			removePlayer(players.length - 1);
		}

		if (stream.stream_type === 'embed') {
			// Embed/iframe player — no hls.js needed
			const newPlayer = {
				id: Date.now(),
				proxyUrl: '',
				originalUrl: stream.embed_url,
				embedUrl: stream.embed_url,
				streamType: 'embed',
				siteKey: stream.site_key || '',
				siteName: stream.site_name || stream.site_key || 'Unknown',
				quality: stream.quality || '',
				isPlaying: true,
				isMuted: false,
				volume: 1,
				showControls: true,
				error: null,
				videoEl: null,
				containerEl: null,
				hls: null,
				controlsTimer: null,
			};
			players = [...players, newPlayer];
			return;
		}

		// m3u8 player — use hls.js
		if (!Hls) return;

		const proxyUrl = getProxyUrl(stream.url);
		const newPlayer = {
			id: Date.now(),
			proxyUrl,
			originalUrl: stream.url,
			embedUrl: '',
			streamType: 'm3u8',
			siteKey: stream.site_key || '',
			siteName: stream.site_name || stream.site_key || 'Unknown',
			quality: stream.quality || '',
			isPlaying: false,
			isMuted: false,
			volume: 1,
			showControls: true,
			error: null,
			videoEl: null,
			containerEl: null,
			hls: null,
			controlsTimer: null,
		};

		players = [...players, newPlayer];

		// Activate stream for token refresh
		activateStream(stream.url, stream.site_key || '').catch(() => {});

		// Wait for DOM to update then initialize player
		requestAnimationFrame(() => {
			requestAnimationFrame(() => {
				initPlayer(players.length - 1);
			});
		});
	}

	function initPlayer(index) {
		const player = players[index];
		if (!player || !player.videoEl) return;

		if (Hls.isSupported()) {
			const hlsInstance = new Hls({
				enableWorker: true,
				lowLatencyMode: true,
				backBufferLength: 90
			});

			hlsInstance.loadSource(player.proxyUrl);
			hlsInstance.attachMedia(player.videoEl);

			hlsInstance.on(Hls.Events.MANIFEST_PARSED, () => {
				player.videoEl.play().catch(() => {});
				players[index] = { ...player, isPlaying: true, hls: hlsInstance };
			});

			hlsInstance.on(Hls.Events.ERROR, (event, data) => {
				if (data.fatal) {
					switch (data.type) {
						case Hls.ErrorTypes.NETWORK_ERROR:
							players[index] = { ...players[index], error: `Network error: ${data.details}` };
							hlsInstance.startLoad();
							break;
						case Hls.ErrorTypes.MEDIA_ERROR:
							players[index] = { ...players[index], error: `Media error: ${data.details}` };
							hlsInstance.recoverMediaError();
							break;
						default:
							players[index] = { ...players[index], error: `Fatal error: ${data.details}` };
							removePlayer(index);
							break;
					}
				}
			});

			player.hls = hlsInstance;
		} else if (player.videoEl.canPlayType('application/vnd.apple.mpegurl')) {
			// Native HLS (Safari)
			player.videoEl.src = player.proxyUrl;
			player.videoEl.addEventListener('loadedmetadata', () => {
				player.videoEl.play().catch(() => {});
				players[index] = { ...player, isPlaying: true };
			});
		}
	}

	function togglePlay(index) {
		const player = players[index];
		if (!player?.videoEl) return;
		if (player.videoEl.paused) {
			player.videoEl.play().catch(() => {});
			players[index] = { ...player, isPlaying: true };
		} else {
			player.videoEl.pause();
			players[index] = { ...player, isPlaying: false };
		}
	}

	function toggleMute(index) {
		const player = players[index];
		if (!player?.videoEl) return;
		const newMuted = !player.isMuted;
		player.videoEl.muted = newMuted;
		players[index] = { ...player, isMuted: newMuted };
	}

	function setVolume(index, e) {
		const player = players[index];
		if (!player?.videoEl) return;
		const vol = parseFloat(e.target.value);
		player.videoEl.volume = vol;
		const muted = vol === 0;
		player.videoEl.muted = muted;
		players[index] = { ...player, volume: vol, isMuted: muted };
	}

	function toggleFullscreen(index) {
		const player = players[index];
		if (!player?.containerEl) return;
		if (!document.fullscreenElement) {
			player.containerEl.requestFullscreen().catch(() => {});
		} else {
			document.exitFullscreen().catch(() => {});
		}
	}

	let isFullscreen = $state(false);
	function onFullscreenChange() {
		isFullscreen = !!document.fullscreenElement;
	}

	function onPlayerMouseMove(index) {
		const player = players[index];
		if (!player) return;
		if (player.controlsTimer) clearTimeout(player.controlsTimer);
		players[index] = { ...player, showControls: true };
		const timer = setTimeout(() => {
			if (players[index]?.isPlaying) {
				players[index] = { ...players[index], showControls: false };
			}
		}, 3000);
		players[index] = { ...players[index], controlsTimer: timer };
	}

	function responseTimeColor(ms) {
		if (ms < 500) return 'text-green-400';
		if (ms < 1500) return 'text-yellow-400';
		return 'text-red-400';
	}
</script>

<svelte:head>
	<title>F1 Stream - Watch{currentRace ? ` - ${currentRace.race_name}` : ''}</title>
</svelte:head>

<div class="max-w-7xl mx-auto px-4 py-6">
	<!-- Session Info Header -->
	{#if currentRace && currentSession}
		<div class="mb-6">
			<p class="text-f1-text-muted text-sm uppercase tracking-wider">
				Round {currentRace.round} &middot; {currentSession.name}
			</p>
			<h1 class="text-2xl font-bold text-white">{currentRace.race_name}</h1>
			<p class="text-f1-text-muted text-sm">{currentRace.circuit} &middot; {currentRace.country}</p>
		</div>
	{:else}
		<h1 class="text-2xl font-bold text-white mb-6">Watch</h1>
	{/if}

	<!-- Multi-Stream Players Grid -->
	{#if players.length > 0}
		<div class="grid {layoutClass} gap-2 mb-6">
			{#each players as player, i (player.id)}
				<div
					class="bg-black rounded-lg overflow-hidden relative group"
					bind:this={player.containerEl}
					onmousemove={() => onPlayerMouseMove(i)}
					role="region"
					aria-label="Video player {i + 1}"
				>
					<!-- Stream label -->
					<div class="absolute top-2 left-2 z-10 bg-black/60 rounded px-2 py-0.5 text-xs text-white">
						{player.siteName}{#if player.quality} &middot; {player.quality}{/if}
					</div>

					<!-- Close button -->
					<button
						onclick={() => removePlayer(i)}
						class="absolute top-2 right-2 z-10 bg-black/60 rounded-full w-6 h-6 flex items-center justify-center text-white hover:text-f1-red hover:bg-black/80 transition-colors"
						aria-label="Close stream"
					>
						<svg class="w-3.5 h-3.5" fill="currentColor" viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>
					</button>

					<!-- Video or Iframe -->
					{#if player.streamType === 'embed'}
						<iframe
							src={player.embedUrl}
							class="w-full aspect-video bg-black"
							allow="autoplay; encrypted-media; fullscreen; picture-in-picture"
							allowfullscreen
							frameborder="0"
							title="{player.siteName} stream"
						></iframe>
					{:else}
						<video
							bind:this={player.videoEl}
							class="w-full aspect-video bg-black"
							playsinline
						></video>
					{/if}

					<!-- Controls Overlay -->
					<div class="absolute bottom-0 left-0 right-0 bg-gradient-to-t from-black/80 to-transparent px-3 py-2 transition-opacity duration-300 {player.showControls ? 'opacity-100' : 'opacity-0'}">
						<div class="flex items-center gap-2">
							<button onclick={() => togglePlay(i)} class="text-white hover:text-f1-red transition-colors" aria-label={player.isPlaying ? 'Pause' : 'Play'}>
								{#if player.isPlaying}
									<svg class="w-5 h-5" fill="currentColor" viewBox="0 0 24 24"><path d="M6 4h4v16H6V4zm8 0h4v16h-4V4z"/></svg>
								{:else}
									<svg class="w-5 h-5" fill="currentColor" viewBox="0 0 24 24"><path d="M8 5v14l11-7z"/></svg>
								{/if}
							</button>

							<button onclick={() => toggleMute(i)} class="text-white hover:text-f1-red transition-colors" aria-label={player.isMuted ? 'Unmute' : 'Mute'}>
								{#if player.isMuted || player.volume === 0}
									<svg class="w-4 h-4" fill="currentColor" viewBox="0 0 24 24"><path d="M16.5 12c0-1.77-1.02-3.29-2.5-4.03v2.21l2.45 2.45c.03-.2.05-.41.05-.63zm2.5 0c0 .94-.2 1.82-.54 2.64l1.51 1.51C20.63 14.91 21 13.5 21 12c0-4.28-2.99-7.86-7-8.77v2.06c2.89.86 5 3.54 5 6.71zM4.27 3L3 4.27 7.73 9H3v6h4l5 5v-6.73l4.25 4.25c-.67.52-1.42.93-2.25 1.18v2.06c1.38-.31 2.63-.95 3.69-1.81L19.73 21 21 19.73l-9-9L4.27 3zM12 4L9.91 6.09 12 8.18V4z"/></svg>
								{:else}
									<svg class="w-4 h-4" fill="currentColor" viewBox="0 0 24 24"><path d="M3 9v6h4l5 5V4L7 9H3zm13.5 3c0-1.77-1.02-3.29-2.5-4.03v8.05c1.48-.73 2.5-2.25 2.5-4.02z"/></svg>
								{/if}
							</button>
							<input
								type="range" min="0" max="1" step="0.05"
								value={player.volume}
								oninput={(e) => setVolume(i, e)}
								class="w-16 h-1 accent-f1-red"
								aria-label="Volume"
							/>

							<div class="flex-1"></div>

							<button onclick={() => toggleFullscreen(i)} class="text-white hover:text-f1-red transition-colors" aria-label="Fullscreen">
								<svg class="w-4 h-4" fill="currentColor" viewBox="0 0 24 24"><path d="M7 14H5v5h5v-2H7v-3zm-2-4h2V7h3V5H5v5zm12 7h-3v2h5v-5h-2v3zM14 5v2h3v3h2V5h-5z"/></svg>
							</button>
						</div>
					</div>

					<!-- Error overlay -->
					{#if player.error}
						<div class="absolute bottom-12 left-2 right-2 bg-red-900/80 rounded px-2 py-1 text-xs text-red-300">
							{player.error}
						</div>
					{/if}
				</div>
			{/each}
		</div>
	{/if}

	<!-- Stream List -->
	{#if loading}
		<div class="flex items-center justify-center py-20">
			<div class="w-8 h-8 border-2 border-f1-red border-t-transparent rounded-full animate-spin"></div>
			<span class="ml-3 text-f1-text-muted">Loading streams...</span>
		</div>
	{:else if errorMsg}
		<div class="bg-red-900/30 border border-red-700 rounded-lg p-4 text-center">
			<p class="text-red-300">Failed to load streams: {errorMsg}</p>
			<button onclick={loadData} class="mt-2 px-4 py-1 bg-f1-red text-white rounded text-sm hover:bg-f1-red-dark transition-colors">
				Retry
			</button>
		</div>
	{:else if streamsData}
		<div class="flex items-center justify-between mb-4">
			<h2 class="text-lg font-semibold text-white">
				Available Streams
				<span class="text-f1-text-muted font-normal text-sm ml-2">({streamsData.count})</span>
			</h2>
			<div class="flex items-center gap-4">
				{#if players.length > 0}
					<span class="text-xs text-f1-text-muted">{players.length}/{MAX_PLAYERS} streams active</span>
				{/if}
				<button onclick={loadData} class="text-xs text-f1-text-muted hover:text-white transition-colors uppercase tracking-wider">
					Refresh
				</button>
			</div>
		</div>

		{#if streamsData.streams.length === 0}
			<div class="bg-f1-surface border border-f1-border rounded-lg p-8 text-center">
				<p class="text-f1-text-muted">No streams available right now.</p>
				<p class="text-f1-text-muted text-sm mt-2">Streams appear when a session is live. Check the schedule for upcoming sessions.</p>
				<a href="/" class="inline-block mt-4 px-4 py-2 bg-f1-surface-hover border border-f1-border rounded text-sm text-white hover:border-f1-red transition-colors">
					View Schedule
				</a>
			</div>
		{:else}
			<div class="space-y-2">
				{#each streamsData.streams as stream, i}
					{@const active = isStreamActive(stream.stream_type === 'embed' ? stream.embed_url : stream.url)}
					<div class="bg-f1-surface border rounded-lg px-4 py-3 flex items-center gap-4 {active ? 'border-f1-red' : 'border-f1-border hover:border-f1-border'}">
						<div class="flex-1 min-w-0">
							<div class="flex items-center gap-2">
								<span class="text-sm font-medium text-white truncate">{stream.site_name || stream.site_key || 'Unknown'}</span>
								{#if stream.is_live}
									<span class="text-[10px] font-bold uppercase px-1.5 py-0.5 rounded bg-f1-red text-white">Live</span>
								{/if}
								{#if stream.stream_type === 'embed'}
									<span class="text-[10px] font-bold uppercase px-1.5 py-0.5 rounded bg-blue-600 text-white">Embed</span>
								{/if}
								{#if active}
									<span class="text-[10px] font-bold uppercase px-1.5 py-0.5 rounded bg-green-600 text-white">Playing</span>
								{/if}
							</div>
							<div class="flex items-center gap-3 mt-1 text-xs text-f1-text-muted">
								{#if stream.title}
									<span class="truncate">{stream.title}</span>
								{/if}
								{#if stream.quality}
									<span>{stream.quality}</span>
								{/if}
								{#if stream.response_time_ms != null}
									<span class={responseTimeColor(stream.response_time_ms)}>
										{stream.response_time_ms}ms
									</span>
								{/if}
							</div>
						</div>

						<div class="flex items-center gap-2">
							{#if !active}
								<button
									onclick={() => playStream(stream)}
									class="px-4 py-1.5 rounded text-sm font-medium bg-f1-red text-white hover:bg-f1-red-dark transition-colors"
								>
									{players.length > 0 ? 'Add' : 'Watch'}
								</button>
							{:else}
								<span class="text-xs text-green-400">Active</span>
							{/if}
						</div>
					</div>
				{/each}
			</div>
		{/if}
	{/if}
</div>
