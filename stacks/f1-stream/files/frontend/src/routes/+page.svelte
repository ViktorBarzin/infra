<script>
	import { fetchSchedule } from '$lib/api.js';
	import { onMount } from 'svelte';

	let scheduleData = $state(null);
	let loading = $state(true);
	let errorMsg = $state(null);
	let now = $state(new Date());

	// Update "now" every 30 seconds for live countdown
	let timer;
	onMount(() => {
		loadSchedule();
		timer = setInterval(() => { now = new Date(); }, 30000);
		return () => clearInterval(timer);
	});

	async function loadSchedule() {
		loading = true;
		errorMsg = null;
		try {
			scheduleData = await fetchSchedule();
		} catch (e) {
			errorMsg = e.message;
		} finally {
			loading = false;
		}
	}

	/**
	 * Find the next upcoming session across all races.
	 */
	let nextSession = $derived.by(() => {
		if (!scheduleData?.races) return null;
		for (const race of scheduleData.races) {
			for (const session of race.sessions) {
				if (session.status === 'upcoming') {
					return { race, session };
				}
				if (session.status === 'live') {
					return { race, session };
				}
			}
		}
		return null;
	});

	/**
	 * Format an ISO date string to the user's local timezone.
	 */
	function formatLocalTime(isoStr) {
		const d = new Date(isoStr);
		return d.toLocaleString(undefined, {
			weekday: 'short',
			month: 'short',
			day: 'numeric',
			hour: '2-digit',
			minute: '2-digit'
		});
	}

	/**
	 * Format a short date (day + month).
	 */
	function formatShortDate(isoStr) {
		const d = new Date(isoStr);
		return d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
	}

	/**
	 * Format a time only.
	 */
	function formatTime(isoStr) {
		const d = new Date(isoStr);
		return d.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' });
	}

	/**
	 * Compute countdown string to a future ISO date.
	 */
	function countdown(isoStr) {
		const target = new Date(isoStr);
		const diff = target - now;
		if (diff <= 0) return 'Now';

		const days = Math.floor(diff / (1000 * 60 * 60 * 24));
		const hours = Math.floor((diff % (1000 * 60 * 60 * 24)) / (1000 * 60 * 60));
		const mins = Math.floor((diff % (1000 * 60 * 60)) / (1000 * 60));

		if (days > 0) return `${days}d ${hours}h ${mins}m`;
		if (hours > 0) return `${hours}h ${mins}m`;
		return `${mins}m`;
	}

	/**
	 * Get status badge classes.
	 */
	function statusClasses(status) {
		switch (status) {
			case 'live': return 'bg-f1-red text-white';
			case 'upcoming': return 'bg-blue-600 text-white';
			case 'past': return 'bg-neutral-700 text-neutral-400';
			default: return 'bg-neutral-700 text-neutral-400';
		}
	}

	/**
	 * Determine if a race has any live or upcoming sessions (to highlight it).
	 */
	function raceIsActive(race) {
		return race.sessions.some(s => s.status === 'live' || s.status === 'upcoming');
	}

	/**
	 * Determine if a race is entirely in the past.
	 */
	function raceIsPast(race) {
		return race.sessions.every(s => s.status === 'past');
	}
</script>

<svelte:head>
	<title>F1 Stream - Schedule</title>
</svelte:head>

<div class="max-w-6xl mx-auto px-4 py-6">
	{#if loading}
		<div class="flex items-center justify-center py-20">
			<div class="w-8 h-8 border-2 border-f1-red border-t-transparent rounded-full animate-spin"></div>
			<span class="ml-3 text-f1-text-muted">Loading schedule...</span>
		</div>
	{:else if errorMsg}
		<div class="bg-red-900/30 border border-red-700 rounded-lg p-4 text-center">
			<p class="text-red-300">Failed to load schedule: {errorMsg}</p>
			<button onclick={loadSchedule} class="mt-2 px-4 py-1 bg-f1-red text-white rounded text-sm hover:bg-f1-red-dark transition-colors">
				Retry
			</button>
		</div>
	{:else if scheduleData}
		<!-- Next Session Countdown -->
		{#if nextSession}
			<div class="mb-8 bg-f1-surface border border-f1-border rounded-lg p-6">
				<div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-2">
					<div>
						<p class="text-f1-text-muted text-sm uppercase tracking-wider">
							{nextSession.session.status === 'live' ? 'Live Now' : 'Next Session'}
						</p>
						<h2 class="text-xl font-bold text-white mt-1">
							{nextSession.race.race_name} - {nextSession.session.name}
						</h2>
						<p class="text-f1-text-muted text-sm mt-1">
							{nextSession.race.circuit} &middot; {nextSession.race.country}
						</p>
					</div>
					<div class="text-right">
						{#if nextSession.session.status === 'live'}
							<a href="/watch" class="inline-flex items-center gap-2 px-5 py-2 bg-f1-red text-white font-semibold rounded-lg hover:bg-f1-red-dark transition-colors">
								<span class="w-2 h-2 rounded-full bg-white animate-pulse"></span>
								Watch Live
							</a>
						{:else}
							<p class="text-2xl font-mono font-bold text-white">{countdown(nextSession.session.start_utc)}</p>
							<p class="text-f1-text-muted text-sm">{formatLocalTime(nextSession.session.start_utc)}</p>
						{/if}
					</div>
				</div>
			</div>
		{/if}

		<!-- Season Header -->
		<div class="flex items-center justify-between mb-6">
			<h1 class="text-2xl font-bold text-white">{scheduleData.season} Season</h1>
			<span class="text-xs text-f1-text-muted">{scheduleData.races.length} races</span>
		</div>

		<!-- Race List -->
		<div class="space-y-4">
			{#each scheduleData.races as race (race.round)}
				{@const isPast = raceIsPast(race)}
				<div class="bg-f1-surface border border-f1-border rounded-lg overflow-hidden {isPast ? 'opacity-50' : ''}">
					<!-- Race Header -->
					<div class="px-4 py-3 flex items-center justify-between">
						<div class="flex items-center gap-3">
							<span class="text-f1-text-muted text-sm font-mono w-8">R{race.round}</span>
							<div>
								<h3 class="font-semibold text-white">{race.race_name}</h3>
								<p class="text-xs text-f1-text-muted">{race.circuit} &middot; {race.locality}, {race.country}</p>
							</div>
						</div>
						<span class="text-sm text-f1-text-muted">{formatShortDate(race.date)}</span>
					</div>

					<!-- Sessions -->
					<div class="border-t border-f1-border">
						<div class="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-px bg-f1-border">
							{#each race.sessions as session}
								{@const isLive = session.status === 'live'}
								{@const isClickable = isLive}
								<div class="bg-f1-surface px-3 py-2 {isLive ? 'bg-f1-red/10' : ''} {isClickable ? 'hover:bg-f1-surface-hover cursor-pointer' : ''}">
									{#if isClickable}
										<a href="/watch?session={session.type}&round={race.round}" class="block">
											<div class="flex items-center justify-between">
												<span class="text-sm font-medium text-white">{session.name}</span>
												<span class="text-[10px] font-bold uppercase px-1.5 py-0.5 rounded {statusClasses(session.status)}">
													{session.status}
												</span>
											</div>
											<p class="text-xs text-f1-text-muted mt-0.5">{formatTime(session.start_utc)}</p>
										</a>
									{:else}
										<div class="flex items-center justify-between">
											<span class="text-sm font-medium {session.status === 'past' ? 'text-f1-text-muted' : 'text-white'}">{session.name}</span>
											<span class="text-[10px] font-bold uppercase px-1.5 py-0.5 rounded {statusClasses(session.status)}">
												{session.status}
											</span>
										</div>
										<p class="text-xs text-f1-text-muted mt-0.5">
											{formatTime(session.start_utc)}
											{#if session.status === 'upcoming'}
												&middot; {countdown(session.start_utc)}
											{/if}
										</p>
									{/if}
								</div>
							{/each}
						</div>
					</div>
				</div>
			{/each}
		</div>
	{/if}
</div>
