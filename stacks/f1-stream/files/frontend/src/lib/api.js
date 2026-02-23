/**
 * API client for the F1 Streams backend.
 * All endpoints are on the same origin, so no CORS issues.
 */

const API_BASE = '';

/**
 * Fetch the F1 race schedule with session statuses.
 * @returns {Promise<{season: string, fetched_at: string, races: Array}>}
 */
export async function fetchSchedule() {
	const res = await fetch(`${API_BASE}/schedule`);
	if (!res.ok) throw new Error(`Schedule fetch failed: ${res.status}`);
	return res.json();
}

/**
 * Fetch available live streams.
 * @returns {Promise<{streams: Array, count: number}>}
 */
export async function fetchStreams() {
	const res = await fetch(`${API_BASE}/streams`);
	if (!res.ok) throw new Error(`Streams fetch failed: ${res.status}`);
	return res.json();
}

/**
 * Encode a URL to base64url for the proxy endpoint.
 * @param {string} rawUrl - The original m3u8 URL
 * @returns {string} base64url-encoded string
 */
function toBase64Url(rawUrl) {
	return btoa(rawUrl).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/**
 * Get the proxied m3u8 URL for HLS playback.
 * @param {string} m3u8Url - The original m3u8 URL
 * @returns {string} The proxy URL
 */
export function getProxyUrl(m3u8Url) {
	const encoded = toBase64Url(m3u8Url);
	return `${API_BASE}/proxy?url=${encoded}`;
}

/**
 * Mark a stream as actively being watched (enables token refresh).
 * @param {string} url - The stream URL
 * @param {string} [siteKey] - Optional site key
 */
export async function activateStream(url, siteKey = '') {
	const res = await fetch(`${API_BASE}/streams/activate`, {
		method: 'POST',
		headers: { 'Content-Type': 'application/json' },
		body: JSON.stringify({ url, site_key: siteKey })
	});
	if (!res.ok) throw new Error(`Activate failed: ${res.status}`);
	return res.json();
}

/**
 * Mark a stream as no longer being watched.
 * @param {string} url - The stream URL
 */
export async function deactivateStream(url) {
	const res = await fetch(`${API_BASE}/streams/deactivate`, {
		method: 'POST',
		headers: { 'Content-Type': 'application/json' },
		body: JSON.stringify({ url })
	});
	if (!res.ok) throw new Error(`Deactivate failed: ${res.status}`);
	return res.json();
}
