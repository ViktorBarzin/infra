# code-quality — is this repo getting easier to work in

Built 2026-09-06, after a 26-branch refactor of terminal-lobby left the codebase
measurably better and 6,795 lines **bigger**. Line count said the work made
things worse. The research behind what to measure instead is in
the terminal-lobby repo at `docs/plans/2026-09-06-code-quality-measurement.md`:
58 metrics, 20 rejected. Moved here from the `~/code` monorepo root
(`docs/agents/code-quality/`) on 2026-11-03, beside `session-reflection/`.

**The point of a repeat run is the trend, not the number.** One run says this
repo has two invisible coupling pairs. Two say whether last month's work removed
them.

## Run it

```sh
homelab quality                      # this repo: measure, record, push, print the delta
homelab quality run ~/code/infra     # a specific repo, or several
homelab quality diff                 # last two runs, side by side
homelab quality history              # every recorded run
homelab quality gate                 # exit 1 if a gated metric regressed, for CI
```

Each `run` writes a snapshot to `history/` next to `quality.py`, in the infra
checkout the CLI found (`~/code/infra`, or `~/code` when that is the infra
clone). Commit it to infra master so `diff` and `history` see it.

Needs nothing but git and python3. About 20 seconds on a 200,000-line repo, zero
model tokens. `run --with-suite` also runs the test suites, which takes minutes
rather than seconds.

## What it measures, and why these

| series | kind | reads |
|---|---|---|
| `sloc{prod,test}` | control | the bar every other metric has to beat |
| `invisible_coupling_pairs` | gate | files that change together with no import linking them |
| `identical_file_pairs` | gate | a coupling pair that is byte-identical, so a copy |
| `max_coupling_degree` | trend | how tightly the worst pair is bound |
| `change_concentration_pct` | trend | share of touches landing in the top 10 files |
| `bug_magnet_files` | trend | files with 5+ fix commits in 180 days |
| `rework_rate_pct` | trend | reverts, plus fixes touching a file changed under 24h ago |

`sloc` is not a quality metric. Borg, Ezzouhri and Tornhill (2024) measured a
naive line-count threshold at AUC 0.95, above every composite they tested, so
it is the bar rather than the weak baseline. `diff` prints its move beside every
other move, and labels a metric that merely tracked it.

### Invisible coupling is the one that earns its place

Two files change together, and nothing a tool can follow connects them. On
terminal-lobby it found both of these before anyone looked at the ranking:

```
0.73  frontend-v2/public/sw.js  <->  frontend/sw.js       IDENTICAL FILES
0.50  frontend-v2/src/telemetry/track.ts  <->  telemetry/events.go   cross-language
```

The first is a byte-identical 496-line copy. The second is a contract between
TypeScript and Go whose only link is a comment at `track.ts:16` saying the union
mirrors the Go catalog, which is why five telemetry events silently drifted out
of sync. No type checker, linter or dependency graph can see either. On `infra`
it found a shell script coupled to the Terraform that configures it, same shape.

A comment does not count as a link. That is deliberate, and it is the whole
finding.

## What it refuses to measure

`detectors.json` has a `banned` block, and `series()` is tested to never emit
those names. Each was measured against line count on the `~/code` monorepo (2026-09-06):

| rejected | measured |
|---|---|
| summed cyclomatic complexity | r=0.910, R²=0.828 against per-file LOC. Reported a false +6,198 regression on the refactor |
| maintainability index | r(MI, ln SLOC) = −0.876 here. Its `-16.2*ln(sloc)` term pays you to split files |
| SQALE debt ratio | Borg et al. 2024: AUC 0.60 against a 0.50 coin flip. Deleting lines raises it |
| Halstead | Hamer and Frewin 1982: not natural laws, not useful engineering approximations |
| test-to-prod ratio | LOC divided by LOC. Moved 9% on a file-selection decision before any code changed |

Re-adding one needs a new measurement, not an opinion.

## Reading a diff honestly

```
invisible_coupling_pairs    3    2    -1   moved against sloc (+4.2%), so not size-shaped
bug_magnet_files           13   19    +6   sloc moved +4.2%, so read this as size-shaped
```

A count falling while the codebase grew is a real improvement. A count rising
alongside size might be nothing. The tool says which, rather than leaving the
reader to claim credit.

## Detectors are data

`detectors.json` holds the thresholds and windows, and every snapshot records a
fingerprint of it. `diff` refuses to compare across a fingerprint change, so
adding a detector never reads as a regression. Same contract as
[`session-reflection`](../session-reflection/README.md), which this mirrors
throughout.

## Known limits

- The import heuristic is line-shaped, so a re-export chain or a generated
  binding can still read as invisible. False positives are visible in the ranked
  list and cheap to dismiss; that is the intended failure direction.
- Wide commits are excluded from coupling at 20 files, since one 200-file commit
  creates 19,900 pairs. The count skipped is reported in every snapshot.
- `duplication` and `layer_violations` are declared but not wired. They need
  jscpd and dependency-cruiser, neither installed. They report themselves absent
  rather than silently scoring zero.
- Coverage, mutation score and vulnerable-dependency counts are in the research
  doc's adopt list and not built here yet.

## Tests

```sh
python3 -m pytest test_quality.py -q
```

Every case is a false positive or false negative a real run produced, not an
invented one. Measurement code fails by emitting a plausible number rather than
by crashing, so the tests lock the specific wrong answers that looked right: a
file paired with its own test at 0.82, a `.tsx`/`.ts` pair called
cross-language, two same-named files excluding each other so the repo scored a
clean zero, and a comment counting as an import.
