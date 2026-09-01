// Classifier for the immich-thumbnail-reconcile CronJob.
//
// Reads /shared/stuck.tsv (id, ownerId, type, originalPath) and decides, per
// asset, whether a thumbnail could still be produced from the original. Writes
// /shared/repair.tsv (ownerId, id) for the ones worth re-enqueuing, and its own
// counts to /shared/metrics.20-classify.prom, which the push step concatenates
// with the other steps'. One file per step, never a shared one: the steps run as
// three different uids and the second writer to a file another created gets
// EPERM.
//
// WHY IT ACTUALLY DECODES THE FILE
//
// Cheap heuristics are not enough to tell "dropped by the pipeline" from "the
// bytes are gone", and getting that wrong is what makes a self-healing job
// useless: a file it wrongly calls repairable is retried every night forever and
// pins the alert on, so the alert stops meaning anything. Measured on
// 2026-09-01, DSCF3872.jpg passes every cheap check — it exists, it is 1.9 MB,
// it is not zero-filled, it ends in a proper ffd9 EOI marker — and libvips still
// refuses it with "Incomplete scan detected". The only honest test is the one
// thumbnail generation itself performs, so this asks sharp/libvips for images
// and ffprobe for videos, which is exactly what the real job would do.
//
// Order matters for IO: stat, then the NUL check on the first 64 KiB, and only
// then a full decode. Files that are obviously destroyed are never read past
// 64 KiB, so the expensive path runs on a handful of assets rather than all of
// them. That keeps this off the shared sdc spindle (bead code-oflt).

const fs = require('node:fs');
const { execFileSync } = require('node:child_process');
const sharp = require('/usr/src/app/server/node_modules/sharp');

const STUCK = '/shared/stuck.tsv';
const REPAIR = '/shared/repair.tsv';
const METRICS = '/shared/metrics.20-classify.prom';

// Owners whose API key is mounted. POST /api/assets/jobs enforces asset.update
// per asset and admin does not inherit it across users, so anything outside this
// set is counted and alerted rather than silently dropped.
const KNOWN_OWNERS = new Set(
  [process.env.VIKTOR_OWNER, process.env.ANCA_OWNER].filter(Boolean),
);

// Ceiling on full decodes per run, so a pathological backlog cannot turn one
// night's reconcile into a library-wide read.
const CLASSIFY_LIMIT = Number(process.env.CLASSIFY_LIMIT || 1000);

const isZeroFilled = (path) => {
  const fd = fs.openSync(path, 'r');
  try {
    const buf = Buffer.alloc(65536);
    const read = fs.readSync(fd, buf, 0, buf.length, 0);
    return buf.subarray(0, read).every((b) => b === 0);
  } finally {
    fs.closeSync(fd);
  }
};

const decodes = async (path, type) => {
  if (type === 'VIDEO') {
    // sharp cannot read a container; thumbnails for video come out of ffmpeg, so
    // ask ffprobe whether a video stream is actually readable.
    execFileSync(
      'ffprobe',
      ['-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=codec_type', '-of', 'csv=p=0', path],
      { stdio: ['ignore', 'pipe', 'pipe'], timeout: 30_000 },
    );
    return true;
  }
  // A full resize, not just metadata(): a truncated or corrupt scan only throws
  // once the decoder walks the entropy-coded data.
  await sharp(path, { failOn: 'error' }).resize(250).webp().toBuffer();
  return true;
};

const main = async () => {
  const lines = fs.existsSync(STUCK)
    ? fs.readFileSync(STUCK, 'utf8').split('\n').filter((l) => l.trim() !== '')
    : [];

  let damaged = 0;
  let repairable = 0;
  let unowned = 0;
  let skipped = 0;
  let decoded = 0;

  const repair = [];

  for (const line of lines) {
    const [id, owner, type, ...rest] = line.split('\t');
    const path = rest.join('\t');
    if (!id || !path) {
      continue;
    }

    let stat;
    try {
      stat = fs.statSync(path);
    } catch {
      damaged += 1;
      continue;
    }
    if (!stat.isFile() || stat.size === 0) {
      damaged += 1;
      continue;
    }

    try {
      if (isZeroFilled(path)) {
        damaged += 1;
        continue;
      }
    } catch {
      damaged += 1;
      continue;
    }

    if (decoded >= CLASSIFY_LIMIT) {
      // Not classified this run. Deliberately not counted as repairable — an
      // unverified asset must never enter the repair list.
      skipped += 1;
      continue;
    }

    decoded += 1;
    try {
      await decodes(path, type);
    } catch {
      damaged += 1;
      continue;
    }

    repairable += 1;
    if (KNOWN_OWNERS.has(owner)) {
      repair.push(`${owner}\t${id}`);
    } else {
      unowned += 1;
    }
  }

  fs.writeFileSync(REPAIR, repair.length ? `${repair.join('\n')}\n` : '');

  const metrics = [
    '# HELP immich_thumbnail_unrepairable_assets Stuck assets whose original cannot be decoded (missing, empty, zero-filled or corrupt).',
    '# TYPE immich_thumbnail_unrepairable_assets gauge',
    `immich_thumbnail_unrepairable_assets ${damaged}`,
    '# HELP immich_thumbnail_repairable_assets Stuck assets whose original still decodes, so a thumbnail can be rebuilt.',
    '# TYPE immich_thumbnail_repairable_assets gauge',
    `immich_thumbnail_repairable_assets ${repairable}`,
    '# HELP immich_thumbnail_repair_unowned Repairable assets owned by a user we hold no API key for.',
    '# TYPE immich_thumbnail_repair_unowned gauge',
    `immich_thumbnail_repair_unowned ${unowned}`,
    '# HELP immich_thumbnail_classify_skipped Stuck assets left unclassified because the per-run decode ceiling was reached.',
    '# TYPE immich_thumbnail_classify_skipped gauge',
    `immich_thumbnail_classify_skipped ${skipped}`,
    '',
  ].join('\n');
  fs.writeFileSync(METRICS, metrics);

  process.stdout.write(
    `classified=${decoded} repairable=${repairable} damaged=${damaged} unowned=${unowned} skipped=${skipped}\n`,
  );
};

main().catch((error) => {
  process.stderr.write(`classify failed: ${error}\n`);
  // Leave an empty repair list rather than a partial one: enqueuing a guess is
  // worse than doing nothing, and the scan_success metric already alerts.
  fs.writeFileSync(REPAIR, '');
  process.exit(1);
});
