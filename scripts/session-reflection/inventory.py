#!/usr/bin/env python3
"""Classify every transcript: real work vs synthetic QA probe. Emit inventory.json."""
import json, os, glob, re, sys

ROOT = '/home/wizard/.claude/projects'
OUT = os.getcwd()

# Synthetic-probe signatures: terminal-lobby / t3 e2e harness sessions.
PROBE_PROJECT = re.compile(r'^-(tmp|var-tmp)', )
PROBE_TEXT = re.compile(
    r'reply with (exactly|only|just)|^say h(i|ello)|count (slowly )?from \d+ to \d+|'
    r'^(QA|QC|UIPROBE|DUPE|PING|PONG|MIRROR|ZULU|BORN|BACK)[A-Z0-9]*\d{6,}|'
    r'perm-probe|qa-harness-scratch|\[terminal-lobby\] adopting', re.I)

def user_texts(path):
    out = []
    try:
        with open(path, errors='replace') as fh:
            for i, line in enumerate(fh):
                if '"role":"user"' not in line:
                    continue
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                m = d.get('message') or {}
                if m.get('role') != 'user':
                    continue
                c = m.get('content')
                if isinstance(c, str):
                    t = c
                elif isinstance(c, list):
                    t = ' '.join(p.get('text', '') for p in c
                                 if isinstance(p, dict) and p.get('type') == 'text')
                else:
                    continue
                t = t.strip()
                if not t:
                    continue
                out.append((i + 1, d.get('timestamp'), t))
    except Exception:
        pass
    return out

sessions = []
for path in sorted(glob.glob(os.path.join(ROOT, '**', '*.jsonl'), recursive=True)):
    if '/subagents/' in path:
        continue
    rel = os.path.relpath(path, ROOT)
    project = rel.split('/')[0]
    turns = user_texts(path)
    # drop hook-injected / system-ish turns for the human-signal count
    human = [t for t in turns if not t[2].startswith('<') and '[Request interrupted' not in t[2]]
    probe_hits = sum(1 for _, _, t in human if PROBE_TEXT.search(t[:200]))
    n = len(human)
    ratio = probe_hits / n if n else 1.0
    synthetic = bool(PROBE_PROJECT.match(project)) or (n > 0 and ratio > 0.5) or n == 0
    total_chars = sum(len(t) for _, _, t in human)
    sessions.append({
        'path': path, 'project': project, 'session': os.path.basename(path)[:-6],
        'human_turns': n, 'probe_ratio': round(ratio, 3), 'synthetic': synthetic,
        'user_chars': total_chars, 'mtime': int(os.path.getmtime(path)),
        'size': os.path.getsize(path),
        'first_ts': next((t[1] for t in human if t[1]), None),
        'last_ts': next((t[1] for t in reversed(human) if t[1]), None),
    })

real = [s for s in sessions if not s['synthetic']]
json.dump(sessions, open(os.path.join(OUT, 'inventory.json'), 'w'), indent=1)
print(f"total sessions      {len(sessions)}")
print(f"synthetic/QA probes {len(sessions) - len(real)}")
print(f"REAL work sessions  {len(real)}")
print(f"real user turns     {sum(s['human_turns'] for s in real):,}")
print(f"real corpus bytes   {sum(s['size'] for s in real)/1e6:.0f} MB")
print()
byproj = {}
for s in real:
    byproj.setdefault(s['project'], [0, 0])
    byproj[s['project']][0] += 1
    byproj[s['project']][1] += s['human_turns']
for p, (c, t) in sorted(byproj.items(), key=lambda kv: -kv[1][1]):
    print(f"  {t:6,} turns  {c:3} sessions  {p}")
