import { writable } from 'svelte/store';

function createJobsStore() {
  const { subscribe, set, update } = writable([]);

  return {
    subscribe,
    set,
    add: (job) => update(jobs => [...jobs, job]),
    updateJob: (jobId, updates) => update(jobs =>
      jobs.map(j => j.id === jobId ? { ...j, ...updates } : j)
    ),
    remove: (jobId) => update(jobs => jobs.filter(j => j.id !== jobId)),
    refresh: async () => {
      try {
        const response = await fetch('/api/jobs');
        if (response.ok) {
          const jobs = await response.json();
          set(jobs);
        }
      } catch (e) {
        console.error('Failed to fetch jobs:', e);
      }
    }
  };
}

export const jobs = createJobsStore();
