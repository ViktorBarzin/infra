<script>
  import FileUpload from './lib/FileUpload.svelte';
  import VoicePicker from './lib/VoicePicker.svelte';
  import JobsList from './lib/JobsList.svelte';
  import AudiobooksList from './lib/AudiobooksList.svelte';
  import { jobs } from './stores/jobs.js';

  let uploadedFilename = $state(null);
  let selectedVoice = $state('af_sky');
  let speed = $state(1.0);
  let useGpu = $state(true);
  let isStarting = $state(false);
  let error = $state(null);
  let currentUser = $state(null);

  // Fetch current user on mount
  $effect(() => {
    fetchCurrentUser();
  });

  async function fetchCurrentUser() {
    try {
      const response = await fetch('/api/me');
      if (response.ok) {
        currentUser = await response.json();
      }
    } catch (e) {
      console.error('Failed to fetch user:', e);
    }
  }

  function handleFileUpload(filename) {
    uploadedFilename = filename;
  }

  async function startConversion() {
    if (!uploadedFilename || !selectedVoice) {
      error = 'Please upload a file and select a voice';
      return;
    }

    error = null;
    isStarting = true;

    try {
      const response = await fetch('/api/jobs', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          filename: uploadedFilename,
          voice: selectedVoice,
          speed: speed,
          use_gpu: useGpu
        })
      });

      if (!response.ok) {
        const data = await response.json();
        throw new Error(data.detail || 'Failed to start conversion');
      }

      const job = await response.json();
      jobs.add(job);

      // Reset form
      uploadedFilename = null;

    } catch (e) {
      error = e.message;
    } finally {
      isStarting = false;
    }
  }

  let canStart = $derived(uploadedFilename && selectedVoice && !isStarting);
</script>

<main>
  <header>
    <div class="header-content">
      <div>
        <h1>Audiblez Web</h1>
        <p class="subtitle">Convert EPUB to Audiobook</p>
      </div>
      {#if currentUser}
        <div class="user-info">
          <span class="user-name">{currentUser.name || currentUser.username}</span>
          <span class="user-email">{currentUser.email}</span>
        </div>
      {/if}
    </div>
  </header>

  <div class="content">
    <div class="form-section">
      <div class="upload-section">
        <FileUpload onUpload={handleFileUpload} />
      </div>

      <div class="voice-section">
        <VoicePicker bind:selectedVoice />
      </div>
    </div>

    <div class="options-section">
      <div class="option">
        <label for="speed">Speed: {speed.toFixed(1)}x</label>
        <input
          type="range"
          id="speed"
          min="0.5"
          max="2"
          step="0.1"
          bind:value={speed}
        />
      </div>

      <div class="option">
        <label>
          <input type="checkbox" bind:checked={useGpu} />
          Use GPU (faster)
        </label>
      </div>

      <button
        class="start-btn"
        disabled={!canStart}
        onclick={startConversion}
      >
        {#if isStarting}
          Starting...
        {:else}
          Start Conversion
        {/if}
      </button>

      {#if error}
        <p class="error">{error}</p>
      {/if}
    </div>

    <JobsList />
    <AudiobooksList />
  </div>
</main>

<style>
  :global(body) {
    margin: 0;
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, sans-serif;
    background: #f5f5f5;
  }

  main {
    max-width: 900px;
    margin: 0 auto;
    padding: 2rem;
  }

  header {
    text-align: center;
    margin-bottom: 2rem;
  }

  .header-content {
    display: flex;
    justify-content: space-between;
    align-items: center;
    text-align: left;
  }

  .user-info {
    display: flex;
    flex-direction: column;
    align-items: flex-end;
    padding: 0.5rem 1rem;
    background: #e8f0fe;
    border-radius: 8px;
  }

  .user-name {
    font-weight: 500;
    color: #333;
  }

  .user-email {
    font-size: 0.75rem;
    color: #666;
  }

  h1 {
    margin: 0;
    color: #333;
    font-size: 2rem;
  }

  .subtitle {
    color: #666;
    margin: 0.25rem 0 0;
  }

  .content {
    background: white;
    border-radius: 12px;
    padding: 1.5rem;
    box-shadow: 0 2px 8px rgba(0, 0, 0, 0.1);
  }

  .form-section {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 1.5rem;
  }

  @media (max-width: 768px) {
    .form-section {
      grid-template-columns: 1fr;
    }
  }

  .options-section {
    margin-top: 1.5rem;
    padding-top: 1.5rem;
    border-top: 1px solid #e0e0e0;
    display: flex;
    flex-wrap: wrap;
    gap: 1rem;
    align-items: center;
  }

  .option {
    display: flex;
    align-items: center;
    gap: 0.5rem;
  }

  .option label {
    font-size: 0.875rem;
    color: #666;
  }

  .option input[type="range"] {
    width: 120px;
  }

  .option input[type="checkbox"] {
    width: 16px;
    height: 16px;
  }

  .start-btn {
    margin-left: auto;
    padding: 0.75rem 1.5rem;
    background: #4a90d9;
    color: white;
    border: none;
    border-radius: 8px;
    font-size: 1rem;
    font-weight: 500;
    cursor: pointer;
    transition: background 0.2s;
  }

  .start-btn:hover:not(:disabled) {
    background: #3a7fc9;
  }

  .start-btn:disabled {
    background: #ccc;
    cursor: not-allowed;
  }

  .error {
    color: #d32f2f;
    font-size: 0.875rem;
    width: 100%;
    margin-top: 0.5rem;
  }
</style>
