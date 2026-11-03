#!/usr/bin/env python3
"""Deterministic detectors over the digests. Locates and scores candidates;
the model agents do the judging, not this script.

D1 correction language   -> moments Viktor redirected me
D2 tool-sequence anomaly -> a homelab verb existed and I used the built-in
D3 memory-recall context -> what the recall hook actually injected, per turn
D4 wins control          -> turns where I reached for our tooling unprompted
"""
import json, glob, os, re, collections

HERE = os.getcwd()

# Patterns live in patterns.json, not here. The 2026-08-31 study found D2
# under-counts BY CONSTRUCTION — 159 kubectl-exec-psql calls were found by hand,
# outside every detector — and adding that pattern should never have needed a
# code change. Edit the JSON; this file just applies it.
PATTERNS = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                       'patterns.json')))
STRONG   = [(re.compile(x['re'], re.I), x['kind']) for x in PATTERNS['d1_strong']]
WEAK     = [(re.compile(x['re'], re.I), x['kind']) for x in PATTERNS['d1_weak']]
D2_RULES = [(re.compile(x['re'], re.I), x['verb'], x['severity']) for x in PATTERNS['d2_rules']]

HOMELAB = re.compile(r'\bhomelab\s+([a-z-]+(?:\s+[a-z-]+)?)')

def score_prompt(t):
    hits = []
    for rx, kind in STRONG:
        if rx.search(t):
            hits.append(('strong', kind))
    for rx, kind in WEAK:
        if rx.search(t):
            hits.append(('weak', kind))
    return hits

d1, d2, d3, d4 = [], [], [], []
verb_use = collections.Counter()
turn_total = 0

for f in sorted(glob.glob(os.path.join(HERE, 'digests', '*.json'))):
    d = json.load(open(f))
    sess, proj = d['session'], d['project']
    for i, t in enumerate(d['turns']):
        turn_total += 1
        prompt = t['prompt']
        tools = t['tools']
        bash = [x for x in tools if x['n'] == 'Bash']
        cmds = [x.get('a', '') or '' for x in bash]
        joined = '\n'.join(cmds)

        # --- D1
        hits = score_prompt(prompt)
        strong = [h for h in hits if h[0] == 'strong']
        if strong or len(hits) >= 2:
            d1.append({'session': sess, 'project': proj, 'turn': i,
                        'line': t['line'], 'ts': t['ts'],
                        'digest': f, 'kinds': sorted({h[1] for h in hits}),
                        'n_strong': len(strong), 'prompt': prompt[:900],
                        'n_tools': len(tools),
                        'recalled_ids': [m['id'] for m in t['recalled']]})

        # --- D2
        for rx, verb, kind in D2_RULES:
            m = rx.search(joined)
            if not m:
                continue
            # did I ALSO use the homelab verb in this turn? then it is not a miss
            used = verb in ' '.join(HOMELAB.findall(joined))
            if used:
                continue
            snippet = next((c for c in cmds if rx.search(c)), '')[:300]
            d2.append({'session': sess, 'project': proj, 'turn': i,
                        'line': t['line'], 'ts': t['ts'], 'digest': f,
                        'verb': verb, 'severity': kind, 'match': m.group(0)[:80],
                        'cmd': snippet, 'n_bash': len(bash),
                        'prompt': prompt[:300]})

        # --- D3
        if t['recalled']:
            d3.append({'session': sess, 'turn': i, 'ts': t['ts'],
                        'ids': [m['id'] for m in t['recalled']],
                        'cats': [m['cat'] for m in t['recalled']]})

        # --- D4 wins: a homelab verb inside the first 4 tool calls
        first = ' '.join((x.get('a') or '') for x in tools[:4])
        fv = HOMELAB.findall(first)
        if fv:
            d4.append({'session': sess, 'project': proj, 'turn': i,
                        'digest': f, 'verbs': fv[:4], 'prompt': prompt[:300],
                        'n_tools': len(tools)})
        for v in HOMELAB.findall(joined):
            verb_use[v] += 1

for name, data in (('d1_corrections', d1), ('d2_anomalies', d2),
                   ('d3_recall', d3), ('d4_wins', d4)):
    json.dump(data, open(os.path.join(HERE, f'{name}.json'), 'w'), indent=1)

# The metrics snapshot: the whole point of a repeat run. Absolute counts answer
# "what is it now"; only a comparable snapshot answers "is it getting better".
# Every number here is a rate or a count over the SAME corpus definition, so two
# runs are comparable even as the corpus grows.
metrics = {
    'sessions_real': len({x['session'] for x in d1} | {x['session'] for x in d2}
                         | {x['session'] for x in d4}) or None,
    'turns': turn_total,
    'd1_corrections': len(d1),
    'd2_anomalies': len(d2),
    'd2_redline': sum(1 for x in d2 if x['severity'].startswith('RED')),
    'd3_turns_with_recall': len(d3),
    'd4_wins': len(d4),
    'd2_by_verb': dict(collections.Counter(x['verb'] for x in d2)),
    'd1_by_kind': dict(collections.Counter(k for x in d1 for k in x['kinds'])),
}
json.dump(metrics, open(os.path.join(HERE, 'metrics.json'), 'w'), indent=1)

print(f"turns scanned        {turn_total:,}")
print(f"D1 correction cands  {len(d1)}   ({100*len(d1)/turn_total:.0f}% of turns)")
print(f"   strong-signal     {sum(1 for x in d1 if x['n_strong'])}")
print(f"D2 tool anomalies    {len(d2)}")
print(f"   RED-LINE hits     {sum(1 for x in d2 if x['severity'].startswith('RED'))}")
print(f"D3 turns w/ recall   {len(d3)}   ({100*len(d3)/turn_total:.0f}% of turns)")
print(f"D4 win turns         {len(d4)}")
print()
print("D2 by verb that was skipped:")
for v, c in collections.Counter(x['verb'] for x in d2).most_common():
    print(f"   {c:5}  {v}")
print()
print("D1 by correction kind:")
for k, c in collections.Counter(k for x in d1 for k in x['kinds']).most_common(14):
    print(f"   {c:5}  {k}")
