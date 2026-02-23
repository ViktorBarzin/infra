import { writable } from 'svelte/store';

/** Schedule data store */
export const schedule = writable(null);

/** Streams data store */
export const streams = writable(null);

/** Loading state */
export const loading = writable(false);

/** Error state */
export const error = writable(null);
