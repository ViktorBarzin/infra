// The expensive half of the session-reflection study: the agent pass that
// JUDGES what the deterministic detectors merely located.
//
// Run it with the Workflow tool, pointing at this file and passing the args the
// detectors produced:
//
//   Workflow({ scriptPath: "<this file>", args: <contents of wf_args.json> })
//
// Produce wf_args.json first — `homelab reflect run --work-dir D` leaves the
// detector output in D, and the README shows the one-liner that turns it into
// the args shape (scratch path, corpus counts, d2 bucket list).
//
// Cost, measured 2026-08-31: 36 agents, 6.8M tokens, 1,656 tool calls, ~105
// minutes. That is why it is on demand and not part of `reflect run` — the
// deterministic half is seconds and free, and most periodic runs only need to
// see whether a number moved.
//
// What it earned on the first run, and why it is worth re-running rather than
// trusting the detectors alone: the three adversarial agents REFUTED 4 of the
// 10 synthesized themes, corrected the headline cost figure from 510 to ~148
// minutes, and caught an off-by-one in the study's OWN tooling that had already
// produced a wrong timeline. Detectors locate; only the judging pass decides,
// and only the adversarial pass stops a plausible-but-wrong theme shipping.
//
// UPDATE THE DATES AND NUMBERS IN THE BRIEF when re-running. The brief below
// states corpus counts and "verified this session" facts from 2026-08-31; stale
// ground truth in a brief is worse than none, because agents trust it.

export const meta = {
  name: 'reflect-on-sessions',
  description: 'Mine 176 real sessions for recurring reasons Claude takes the wrong path, and propose verified fixes',
  phases: [
    { title: 'Detect', detail: '10 correction batches + 12 tool-anomaly buckets + 5 memory + 4 wins' },
    { title: 'Synthesize', detail: 'merge, dedupe, date-partition, rank by measured cost' },
    { title: 'Challenge', detail: '3 adversarial verifiers per theme + 1 completeness critic' },
  ],
}

const S = args.scratch
const CORPUS = args.corpus

const BRIEF = `
You are one agent in a study of how Claude Code works on Viktor Barzin's homelab devvm.
GOAL: find recurring, FIXABLE reasons Claude takes the wrong path when a better homelab
capability already existed. Viktor's complaint, paraphrased: Claude often has to be told
which homelab tool to test with, for example the cluster Android emulator to reproduce an
Android-only bug, when it should already know.

CORPUS (already extracted for you, do NOT re-parse raw jsonl unless you need a detail):
  ${CORPUS.sessions} real sessions, ${CORPUS.human_turns} human turns, ${CORPUS.tool_calls} tool calls, span ${CORPUS.span}.
  Synthetic QA-probe sessions are already excluded. Harness-injected user turns
  (skill bodies, compaction summaries, teammate messages) are already excluded.

DATA FILES (all under ${S}):
  digests/<project>__<session>.json  one file per session. Each turn has:
      prompt (what Viktor typed), tools[] ({n: tool name, a: arg sketch}), says[]
      (what Claude replied), recalled[] (memory ids+relevance the recall hook injected
      for that turn), interrupted, compacted_after, line, ts
  d1_corrections.json   86 turns where Viktor's language signals a correction
  d2_anomalies.json     1263 turns where a built-in was used and a homelab verb existed
  d3_recall.json        per-turn memory-recall injections
  d4_wins.json          239 turns where Claude reached for a homelab verb unprompted
  manifest.json         session index

READ A WINDOW (your main tool, much cheaper than reading digests raw):
  python3 ${S}/window.py --session <session-id> <turn> --before 2 --after 3 --tools 40
  It prints Viktor's words, Claude's tool sequence, what Claude said, which memories
  were injected with their relevance scores, and minutes until Viktor's next turn.

GROUND TRUTH about the environment (verified this session, trust it):
  - 77 'homelab' verbs exist. Verb usage over the last 30 days across ALL users
    (from Loki): vault get 3373, logs query 3037, metrics query 2478, memory recall 1820,
    browser run 482, ci status 446, services 85, claude-usage 31, pages publish 29.
    ZERO uses: work start, work land, work clean, k8s debug, net check, paste, share.
  - 'homelab services' lists 156 self-hosted services INCLUDING
    'android-emulator.viktorbarzin.me - Android Emulator - Shared Android testing
    instance (adb + noVNC)'. The capability Viktor complained about EXISTED and was listed.
  - The org-wide rule says to check 'homelab services' "before reaching for an external
    tool or publishing outside the homelab". It does NOT say to check it when Claude
    needs to REPRODUCE or TEST something. That wording gap is a live hypothesis.
  - On 2026-08-15 a fix already landed in the ORG managed-settings claudeMd for the
    logs/metrics theme, naming both the moment and the competitor ("reach for logs query
    BEFORE kubectl logs, journalctl, or writing your own client"). It verified on re-run.
    Any theme whose occurrences ALL predate 2026-08-15 and match that fix is ALREADY
    ADDRESSED - mark it already_fixed, do not propose re-fixing it.
  - Memory recall runs as a UserPromptSubmit hook: it queries 'homelab memory recall
    <the raw user prompt>' at TURN START ONLY, injects the top 5 UNSEEN results, and
    writes their ids to a per-session seen-file so an id is never re-injected that
    session. Measured: 4570 injections, median relevance 0.37, 45% score below 0.35.
  - Infra policy red-line: infra changes go through Terraform/Terragrunt, NEVER direct
    kubectl apply/edit/patch.

RULES FOR YOUR OUTPUT:
  1. EVIDENCE OR IT DOES NOT SHIP. Every finding cites session id + turn + a short
     verbatim quote. No inferred anecdotes.
  2. REDACT. Transcripts may contain personal and credential material. Never quote any of it. If a finding sits in such a session, describe the
     context generically ("a personal-finance analysis") and quote only the
     tool-choice correction itself. Never reproduce a secret, token, or password.
  3. Distinguish a REAL miss from a FALSE POSITIVE. A deterministic regex flagged these
     candidates; you are the judge. 'git worktree add' in a repo where 'homelab work
     start' does not apply is NOT a miss. A curl to a homelab domain inside a script
     Claude was asked to write is NOT a miss. Say so and mark false_positive.
  4. MEASURE COST. cost_turns = turns from the wrong path starting until it was
     corrected or abandoned. cost_minutes from the timestamps window.py prints.
  5. Fix shapes Viktor approved, in his order of preference: (a) reword an existing rule
     so it names BOTH the moment and the built-in competitor it must beat, (b) new or
     changed skill, (c) change the homelab CLI or 'homelab services' output, (d) anything
     else that reliably stops the wrong path. He did NOT tick "new hooks" but did not
     rule them out. Prefer (a).
  6. Landing target: tooling/capability facts belong ORG-WIDE
     (infra/scripts/workstation/managed-settings.json claudeMd), or into a user's own
     AGENTS.md (docs/agents/users/<user>/ in the monorepo; Viktor's in his dotfiles
     agents/core.md and agents/personal.md). Say which for each fix.
  7. Report USER-SIDE findings too, honestly, in a separate class. If misses correlate
     with prompts that omitted context, mid-turn interrupts, or instructions that
     contradict across sessions, say so with evidence. Do not manufacture these to be
     balanced, and do not suppress them to be safe.
  8. A theme needs >= 2 independent occurrences to be a theme. One-offs go in notes.
`

const FINDINGS_SCHEMA = {
  type: 'object',
  required: ['findings', 'notes', 'coverage'],
  properties: {
    coverage: { type: 'string', description: 'exactly what you examined, and anything you could not cover' },
    notes: { type: 'string', description: 'one-off observations, false-positive patterns, surprises' },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        required: ['theme_slug', 'theme_title', 'klass', 'occurrences', 'evidence',
                   'cost_turns', 'cost_minutes', 'blocked_mechanism', 'proposed_fix',
                   'confidence', 'already_fixed'],
        properties: {
          theme_slug: { type: 'string' },
          theme_title: { type: 'string' },
          klass: { type: 'string', enum: ['capability-miss', 'policy-violation',
            'memory-failure', 'preference-drift', 'workflow-inefficiency',
            'user-side', 'other'] },
          occurrences: { type: 'integer' },
          first_seen: { type: 'string' },
          last_seen: { type: 'string' },
          already_fixed: { type: 'boolean' },
          already_fixed_note: { type: 'string' },
          evidence: {
            type: 'array',
            items: {
              type: 'object',
              required: ['session', 'turn', 'quote', 'what_claude_did', 'what_existed'],
              properties: {
                session: { type: 'string' }, turn: { type: 'integer' },
                ts: { type: 'string' },
                quote: { type: 'string', description: 'short verbatim, redacted if sensitive' },
                what_claude_did: { type: 'string' },
                what_existed: { type: 'string', description: 'the homelab capability that was available' },
                false_positive: { type: 'boolean' },
              },
            },
          },
          cost_turns: { type: 'integer' },
          cost_minutes: { type: 'number' },
          blocked_mechanism: { type: 'string', enum: ['rule-existed-not-fired',
            'rule-wording-wrong-moment', 'memory-existed-not-injected',
            'memory-injected-but-ignored', 'services-not-consulted',
            'nothing-existed', 'unknown'] },
          proposed_fix: {
            type: 'object',
            required: ['shape', 'target', 'change_sketch', 'landing'],
            properties: {
              shape: { type: 'string', enum: ['reword-rule', 'new-skill', 'change-skill',
                'homelab-cli', 'services-output', 'hook', 'other'] },
              target: { type: 'string', description: 'exact file or command to change' },
              change_sketch: { type: 'string', description: 'the actual wording or behaviour change, concrete enough to implement' },
              landing: { type: 'string', enum: ['org-wide', 'personal'] },
            },
          },
          confidence: { type: 'string', enum: ['high', 'medium', 'low'] },
        },
      },
    },
  },
}

phase('Detect')

const D1_BATCHES = 10
const d1Jobs = Array.from({ length: D1_BATCHES }, (_, i) => () => agent(
  `${BRIEF}

YOUR JOB - correction batch ${i + 1} of ${D1_BATCHES} (detector D1: what Viktor said).

Load the candidates and take YOUR slice, deterministically:
  python3 -c "
import json
d=json.load(open('${S}/d1_corrections.json'))
mine=[x for k,x in enumerate(d) if k % ${D1_BATCHES} == ${i}]
print(json.dumps([{k:v for k,v in c.items() if k!='digest'} for c in mine], indent=1))
"

For EVERY candidate in your slice:
  1. Read the window: python3 ${S}/window.py --session <session> <turn> --before 2 --after 4 --tools 40
  2. Decide: is this genuinely Viktor redirecting Claude, or is it a false positive
     (a question, a new instruction, a design discussion, a quote of someone else)?
  3. If genuine: what did Claude do, what should it have done, what homelab capability
     existed, and WHY did nothing stop it? Check whether a memory was injected that turn
     (window.py prints ids + relevance). Read a memory in full with:
     homelab memory get <id>
  4. Measure cost_turns and cost_minutes.
  5. Group into themes. Emit one finding per theme, not per occurrence.

Be exhaustive within your slice. Every candidate examined, false positives named.
Run quiet. Your final output is the structured object, not prose for a human.`,
  { label: `corrections:${i + 1}`, phase: 'Detect', schema: FINDINGS_SCHEMA }))

const d2Jobs = args.d2_buckets.map((b, i) => () => agent(
  `${BRIEF}

YOUR JOB - tool-anomaly bucket "${b.verb}" (detector D2: what Claude actually did).
A deterministic rule flagged ${b.count} turns where Claude used a built-in and the
homelab verb "${b.verb}" existed and was not used in that turn. You are the judge.

Load your bucket:
  python3 -c "
import json
d=json.load(open('${S}/d2_anomalies.json'))
mine=[x for x in d if x['verb']=='${b.verb}']
print(len(mine));
print(json.dumps([{k:v for k,v in c.items() if k!='digest'} for c in mine][:120], indent=1))
"

Work method:
  1. Read what the verb actually does before judging anything:
     homelab ${b.verb.split(' /')[0]} --help  2>&1 | head -30   (or: homelab | grep -i '<verb>')
     Some flagged commands are NOT misses. Establish the real boundary first.
  2. Sample windows across the WHOLE date range, not just the first few:
     python3 ${S}/window.py --session <session> <turn> --before 1 --after 2 --tools 40
     Cover at least 12 distinct occurrences spread over the span, more if the bucket is
     large or heterogeneous. Deliberately look for the STRONGEST false-positive case.
  3. Classify the bucket: what fraction are real misses vs false positives? Which
     SUB-PATTERNS are real? (e.g. "kubectl logs on an in-cluster service" is a real miss;
     "kubectl logs while writing a script for someone else" is not.)
  4. For real misses: was Viktor ever forced to correct it, or did it pass unnoticed?
     Cross-check d1_corrections.json for the same session+turn.
  5. Date-partition. If every real miss predates 2026-08-15 and the landed org fix
     covers it, mark already_fixed.
  6. Cost: for this bucket, what did the wrong path actually cost in turns and minutes?
     Compare the tool-call count of the wrong path against what the verb would have taken.

Special instruction for "${b.verb}":
  - If your verb is 'tf apply / policy', those are kubectl apply/edit/patch/delete calls.
    Check EACH ONE against the red-line "infra changes go through Terraform, never direct
    kubectl". Distinguish a genuine policy breach from a read-only or scratch-namespace
    use. This is the highest-severity bucket; be precise, not alarming.
  - If your verb is 'android-emulator', this is Viktor's own example. Establish exactly
    what happened: was an Android/mobile issue being reproduced, was the shared emulator
    reachable at the time, what did Claude do instead, and did Viktor have to say it.
  - If your verb is 'work start' or 'work land', check whether the worktree-first rule in
    the user's AGENTS.md (the Execution part) documents the manual git commands rather than the
    homelab verb. If the RULE ITSELF teaches the manual path, that is the finding.

Be exhaustive. Name your false-positive rate. Run quiet.`,
  { label: `anomaly:${b.verb.replace(/[^a-z]/gi, '-')}`, phase: 'Detect', schema: FINDINGS_SCHEMA }))

const MEM_ANGLES = [
  { k: 'timing', q: `Is recall MISTIMED? The hook queries on the raw user prompt at turn start. Test the hypothesis that capability facts are needed MID-turn. For >=15 confirmed misses (cross-reference d1_corrections.json and d2_anomalies.json), check what was injected on that turn and whether a memory that WOULD have prevented the miss existed in the store at all: homelab memory recall "<the capability, phrased as the decision Claude faced>" --limit 5. Report the rate at which the preventing memory (a) did not exist, (b) existed but was not injected, (c) was injected and ignored.` },
  { k: 'suppression', q: `Does the per-session seen-file suppression hurt? An id is injected at most once per session, and sessions here run up to 138 turns. Find sessions where a high-value memory was injected in an EARLY turn and the miss it would have prevented happened in a LATER turn of the SAME session. Use the digests' per-turn recalled[] lists. Quantify how often this shape occurs.` },
  { k: 'relevance', q: `Is recall being outranked? Measured: 4570 injections, median relevance 0.37, 45% below 0.35. Sample 25 turns across projects, read what was injected vs what the turn actually needed, and judge how many injections were USEFUL. Report a useful-injection rate with examples. Also check: do standing capability/invariant memories lose to topically-closer project memories?` },
  { k: 'compaction', q: `Does compaction drop injected memories? Digest turns carry compacted_after. Find sessions that compacted and check whether facts injected pre-compaction stopped influencing behaviour after it. Also check whether the same miss recurs after a compaction in the same session.` },
  { k: 'store-quality', q: `Is the STORE itself the problem for capability facts? Query it the way a mid-task decision would: homelab memory recall "how do I test an android app", "reproduce a mobile bug", "which browser tool for a bot-walled site", "create a worktree", "check if a service is reachable". For each, judge whether the top-5 answer would actually steer Claude right. Missing or unfindable capability facts are the finding. Do NOT store anything; this is read-only.` },
]

const memJobs = MEM_ANGLES.map((a, i) => () => agent(
  `${BRIEF}

YOUR JOB - detector D3, memory-recall efficacy, angle "${a.k}".
Viktor's report, paraphrased: memories do not always surface when they would help.
Your angle: ${a.q}

Method: work from the digests (recalled[] per turn) and window.py, and query the live
store read-only with 'homelab memory recall' / 'homelab memory get <id>'. NEVER store,
update or delete a memory. Produce NUMBERS, not impressions: rates, counts, denominators.
State your denominator for every rate you report.

Fix shapes worth considering for this class, if the evidence supports them: promote
load-bearing capability facts out of probabilistic recall into a deterministic surface;
re-inject high-importance memories after compaction; drop seen-suppression above an
importance threshold; change what the hook queries on. Only propose what YOUR evidence
supports, and say plainly if your angle turns out not to be a real problem.

Run quiet.`,
  { label: `memory:${a.k}`, phase: 'Detect', schema: FINDINGS_SCHEMA }))

const WIN_ANGLES = [
  'What TRIGGERED the correct choice? Read 30 win turns from d4_wins.json spread across projects and dates. For each, identify why Claude reached for the homelab verb: an explicit rule naming that moment, Viktor naming it in the prompt, a prior turn establishing it, a memory injection, or the absence of any built-in competitor. Rank the triggers by how often they actually worked.',
  'Which rule WORDINGS work? The verbs with heavy use are logs query, metrics query, vault get, memory recall, browser run, ci status. The verbs with zero use are work start, work land, work clean, k8s debug, net check, paste, share. Read how each group is documented in /etc/claude-code/managed-settings.json (claudeMd), ~/.claude/rules/*.md, and ~/code/CLAUDE.md. Extract the concrete linguistic difference between a wording that gets obeyed and one that does not. This is the template every proposed fix should copy.',
  'Does Viktor naming a tool work better than a rule? Compare win turns where Viktor named the tool against win turns where Claude chose it unprompted. Quantify how much of our current success depends on Viktor doing the steering, since that is exactly the labour he wants to stop doing.',
  'Where does the CURRENT setup already do this well? Find the mechanisms already working (the fixer-suggest.py PostToolUse hook, the memory-recall hook, org claudeMd wording, skills that fire reliably). Read ~/.claude/hooks/fixer-suggest.py. Report what makes them work, so fixes copy a proven pattern rather than inventing one. Also flag anything a proposed fix might BREAK.',
]

const winJobs = WIN_ANGLES.map((q, i) => () => agent(
  `${BRIEF}

YOUR JOB - detector D4, the wins control group. We are studying SUCCESS to learn what
actually steers Claude, so the fixes copy a proven pattern instead of a theory.
Your angle: ${q}

Emit findings in the same schema. For this detector a "finding" is a mechanism that
WORKS (klass: other, proposed_fix.shape: whatever generalises it) or a warning that a
proposed fix would break something. Be concrete about wording: quote the exact sentences
that work and the exact sentences that do not. Run quiet.`,
  { label: `wins:${i + 1}`, phase: 'Detect', schema: FINDINGS_SCHEMA }))

log(`Detect: ${d1Jobs.length} correction batches + ${d2Jobs.length} anomaly buckets + ${memJobs.length} memory angles + ${winJobs.length} wins angles = ${d1Jobs.length + d2Jobs.length + memJobs.length + winJobs.length} agents`)

// Barrier is correct here: synthesis must dedupe and rank across ALL detectors at once.
const raw = await parallel([...d1Jobs, ...d2Jobs, ...memJobs, ...winJobs])
const ok = raw.filter(Boolean)
const allFindings = ok.flatMap(r => (r.findings || []))
log(`Detect done: ${ok.length}/${raw.length} agents returned, ${allFindings.length} raw findings`)

phase('Synthesize')

const SYNTH_SCHEMA = {
  type: 'object',
  required: ['themes', 'appendix', 'headline', 'user_side', 'already_fixed'],
  properties: {
    headline: { type: 'string', description: 'the single most important conclusion, one sentence' },
    themes: {
      type: 'array',
      description: 'top 10 by measured cost, most costly first',
      items: {
        type: 'object',
        required: ['rank', 'slug', 'title', 'klass', 'occurrences', 'cost_turns',
                   'cost_minutes', 'root_cause', 'evidence', 'fix', 'confidence'],
        properties: {
          rank: { type: 'integer' }, slug: { type: 'string' }, title: { type: 'string' },
          klass: { type: 'string' }, occurrences: { type: 'integer' },
          cost_turns: { type: 'integer' }, cost_minutes: { type: 'number' },
          first_seen: { type: 'string' }, last_seen: { type: 'string' },
          root_cause: { type: 'string' },
          blocked_mechanism: { type: 'string' },
          evidence: { type: 'array', items: { type: 'object',
            required: ['session', 'turn', 'quote'],
            properties: { session: { type: 'string' }, turn: { type: 'integer' },
              quote: { type: 'string' }, what_claude_did: { type: 'string' },
              what_existed: { type: 'string' } } } },
          fix: { type: 'object',
            required: ['shape', 'target', 'change_sketch', 'landing', 'verifiable_by'],
            properties: { shape: { type: 'string' }, target: { type: 'string' },
              change_sketch: { type: 'string' }, landing: { type: 'string' },
              verifiable_by: { type: 'string', description: 'the exact blind-agent replay prompt that would prove the fix works' } } },
          confidence: { type: 'string' },
        },
      },
    },
    appendix: { type: 'array', description: 'the long tail, one row each',
      items: { type: 'object', required: ['slug', 'title', 'occurrences', 'note'],
        properties: { slug: { type: 'string' }, title: { type: 'string' },
          occurrences: { type: 'integer' }, klass: { type: 'string' },
          note: { type: 'string' }, proposed_fix: { type: 'string' } } } },
    user_side: { type: 'array', description: 'findings that point at Viktor, honestly, separate',
      items: { type: 'object', required: ['title', 'evidence_summary', 'suggestion'],
        properties: { title: { type: 'string' }, evidence_summary: { type: 'string' },
          occurrences: { type: 'integer' }, suggestion: { type: 'string' } } } },
    already_fixed: { type: 'array', description: 'themes whose occurrences predate a landed fix',
      items: { type: 'object', required: ['slug', 'why'],
        properties: { slug: { type: 'string' }, why: { type: 'string' } } } },
    dropped: { type: 'string', description: 'what you deliberately left out, so nothing is silently truncated' },
  },
}

const synth = await agent(
  `${BRIEF}

YOUR JOB - synthesis. ${ok.length} detector agents examined the corpus and returned
${allFindings.length} raw findings. Merge them into ONE ranked picture.

RAW FINDINGS (JSON):
${JSON.stringify(allFindings).slice(0, 420000)}

DETECTOR COVERAGE AND NOTES:
${JSON.stringify(ok.map(r => ({ coverage: r.coverage, notes: r.notes }))).slice(0, 90000)}

Do this:
  1. MERGE duplicates. Different detectors saw the same theme from different angles;
     one theme, evidence pooled, occurrences summed without double-counting the same
     session+turn.
  2. DROP false positives and anything whose evidence does not hold up. If a detector
     asserted something without a session+turn citation, drop it or demote it to appendix.
  3. DATE-PARTITION. Anything whose occurrences all predate 2026-08-15 and is covered by
     the landed org claudeMd fix goes in already_fixed, NOT in themes.
  4. RANK BY MEASURED COST (turns and minutes actually burned), not by raw frequency.
     Viktor ranks by what he felt. Top 10 get full treatment; everything else is one
     appendix row. Say in 'dropped' what you left out.
  5. For each theme name the ROOT CAUSE mechanically: which mechanism should have caught
     it and why it did not fire. "Claude forgot" is not a root cause.
  6. Every fix must be CONCRETE enough to implement without further research: exact file,
     exact wording change. Copy the linguistic pattern the wins detectors found to work.
     Each fix carries verifiable_by: the exact prompt a blind agent would be given to
     prove the fix works.
  7. USER-SIDE findings stay in their own section, evidenced, neither inflated nor suppressed.
  8. Respect the redaction rule in every quote you carry forward.

Run quiet.`,
  { label: 'synthesize', phase: 'Synthesize', schema: SYNTH_SCHEMA, effort: 'high' })

log(`Synthesis: ${synth ? (synth.themes || []).length : 0} themes, ${synth ? (synth.appendix || []).length : 0} appendix rows`)

phase('Challenge')

const VERDICT_SCHEMA = {
  type: 'object',
  required: ['verdicts', 'summary'],
  properties: {
    summary: { type: 'string' },
    verdicts: { type: 'array', items: { type: 'object',
      required: ['slug', 'refuted', 'reason'],
      properties: {
        slug: { type: 'string' },
        refuted: { type: 'boolean', description: 'true if the theme or its fix does not hold up' },
        reason: { type: 'string' },
        evidence_checked: { type: 'string', description: 'the session+turn you actually opened to check' },
        cost_realistic: { type: 'boolean' },
        fix_would_work: { type: 'boolean' },
        better_fix: { type: 'string' },
      } } },
  },
}

const LENSES = [
  { k: 'evidence', q: `Verify the CITATIONS. For every theme, open at least one cited session+turn with window.py and confirm the quote is real, in context, and means what the theme claims. A quote lifted out of context, a "correction" that was actually a new instruction, or a cited turn that does not exist REFUTES the theme. Default to refuted=true when you cannot confirm the citation.` },
  { k: 'causality', q: `Attack the ROOT CAUSE. For every theme, ask whether the named mechanism really failed, or whether something else explains it: the capability did not exist yet at that date, Viktor's instruction was genuinely ambiguous, the built-in was actually the right call, or the "miss" cost nothing. Check dates against when each homelab verb shipped. Refute themes whose causal story does not survive.` },
  { k: 'fix-efficacy', q: `Attack the FIXES. For each proposed fix ask: would this actually have changed the behaviour in the cited turns? Is it just more prose in a file Claude already "read"? Does it duplicate a rule that already exists and already failed? Would it fire at the wrong moment, or fire so often it becomes noise? Count how much text each fix adds to always-loaded context and whether that is worth it. Propose a better fix where you can. A fix that cannot be distinguished from the status quo REFUTES its theme's actionability.` },
]

const challenges = await parallel(LENSES.map(l => () => agent(
  `${BRIEF}

YOUR JOB - adversarial verification, lens "${l.k}". You are BRIEFED TO DISPROVE.
Your value is in what you refute, not in agreeing. Default to refuted=true when uncertain.
You are advisory: your dissent gets surfaced to Viktor, it does not silently overrule.

${l.q}

THEMES UNDER TEST:
${JSON.stringify((synth && synth.themes) || []).slice(0, 300000)}

USER-SIDE CLAIMS UNDER TEST (hold these to the SAME evidentiary bar; an unfair
finding about Viktor is worse than no finding):
${JSON.stringify((synth && synth.user_side) || []).slice(0, 40000)}

Open the real windows. Do not reason from the summary alone. Run quiet.`,
  { label: `challenge:${l.k}`, phase: 'Challenge', schema: VERDICT_SCHEMA, effort: 'high' })))

const critic = await agent(
  `${BRIEF}

YOUR JOB - completeness critic. The study is done; find what it MISSED.

WHAT WAS EXAMINED:
${JSON.stringify(ok.map(r => r.coverage)).slice(0, 60000)}

THEMES PRODUCED:
${JSON.stringify(((synth && synth.themes) || []).map(t => ({ slug: t.slug, title: t.title, klass: t.klass, occurrences: t.occurrences }))).slice(0, 30000)}

APPENDIX:
${JSON.stringify((synth && synth.appendix) || []).slice(0, 30000)}

Ask, and answer with evidence:
  1. Which of the 77 homelab verbs, or which of the 156 self-hosted services, never
     appeared anywhere in this study? Run 'homelab services' and 'homelab' and diff
     against what the themes mention. An unexamined capability is a blind spot.
     Spot-check 2 or 3 of them against the digests for missed misses.
  2. Which failure MODES were not looked for at all? The detectors searched for
     correction language, a fixed list of 12 verb-vs-builtin patterns, memory recall,
     and wins. What class of "wrong path" would all four have missed entirely?
     Grep the digests to test at least one such hypothesis yourself.
  3. Which PROJECTS or date ranges are under-covered relative to their turn count?
     Check manifest.json against the evidence cited in the themes.
  4. Is any theme actually two themes, or are two themes actually one?
  5. What would you examine with another 10 agents?

Emit findings in the FINDINGS_SCHEMA shape: each gap is a finding whose proposed_fix is
the investigation that should be run. Be specific and short. Run quiet.`,
  { label: 'completeness-critic', phase: 'Challenge', schema: FINDINGS_SCHEMA, effort: 'high' })

const verdicts = challenges.filter(Boolean).flatMap(c => c.verdicts || [])
const refutedCount = {}
for (const v of verdicts) {
  if (v.refuted) refutedCount[v.slug] = (refutedCount[v.slug] || 0) + 1
}
const survived = ((synth && synth.themes) || []).filter(t => (refutedCount[t.slug] || 0) < 2)
const killed = ((synth && synth.themes) || []).filter(t => (refutedCount[t.slug] || 0) >= 2)

log(`Challenge: ${survived.length} themes survived, ${killed.length} refuted by majority`)

return {
  headline: synth && synth.headline,
  agents_run: raw.length + challenges.length + 2,
  detectors_returned: `${ok.length}/${raw.length}`,
  raw_finding_count: allFindings.length,
  themes_survived: survived,
  themes_refuted: killed.map(t => ({ slug: t.slug, title: t.title,
    refuted_by: refutedCount[t.slug],
    reasons: verdicts.filter(v => v.slug === t.slug && v.refuted).map(v => v.reason) })),
  challenge_summaries: challenges.filter(Boolean).map(c => c.summary),
  dissent_on_survivors: verdicts.filter(v => v.refuted && (refutedCount[v.slug] || 0) < 2),
  better_fixes: verdicts.filter(v => v.better_fix).map(v => ({ slug: v.slug, better_fix: v.better_fix })),
  appendix: (synth && synth.appendix) || [],
  user_side: (synth && synth.user_side) || [],
  already_fixed: (synth && synth.already_fixed) || [],
  dropped: synth && synth.dropped,
  completeness_gaps: (critic && critic.findings) || [],
  critic_notes: critic && critic.notes,
}
