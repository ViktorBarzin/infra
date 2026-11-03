#!/usr/bin/env python3
"""Print a readable window around one turn of a session digest.

Usage:
  python3 window.py <digest.json> <turn_index> [--before N] [--after N] [--tools N]
  python3 window.py --session <session-id> <turn_index> [...]
"""
import json, sys, glob, os, argparse, datetime

HERE = os.getcwd()

def fmt_ts(ts):
    if not ts: return '?'
    return ts.replace('T', ' ')[:19]

def mins(a, b):
    try:
        pa = datetime.datetime.fromisoformat(a.replace('Z', '+00:00'))
        pb = datetime.datetime.fromisoformat(b.replace('Z', '+00:00'))
        return round((pb - pa).total_seconds() / 60, 1)
    except Exception:
        return None

ap = argparse.ArgumentParser()
ap.add_argument('digest', nargs='?')
ap.add_argument('turn', type=int)
ap.add_argument('--session')
ap.add_argument('--before', type=int, default=1)
ap.add_argument('--after', type=int, default=1)
ap.add_argument('--tools', type=int, default=60)
a = ap.parse_args()

path = a.digest
if a.session:
    hits = glob.glob(os.path.join(HERE, 'digests', f'*{a.session}*.json'))
    if not hits:
        sys.exit(f'no digest for session {a.session}')
    path = hits[0]

d = json.load(open(path))
lo = max(0, a.turn - a.before)
hi = min(len(d['turns']) - 1, a.turn + a.after)
print(f"SESSION {d['session']}  PROJECT {d['project']}  turns={d['n_turns']}")
print(f"RAW {d['path']}")
print('=' * 78)
for i in range(lo, hi + 1):
    t = d['turns'][i]
    mark = '>>> TARGET' if i == a.turn else '    '
    print(f"\n{mark} TURN {i}  line {t['line']}  {fmt_ts(t['ts'])}"
          f"{'  [INTERRUPTED]' if t.get('interrupted') else ''}"
          f"{'  [COMPACTED AFTER]' if t.get('compacted_after') else ''}")
    if t['recalled']:
        ids = ', '.join(f"#{m['id']}({m['score']})" for m in t['recalled'][:8])
        print(f"    RECALLED {len(t['recalled'])} memories: {ids}")
    else:
        print(f"    RECALLED none")
    print(f"    VIKTOR: {' '.join(t['prompt'].split())[:1500]}")
    tl = t['tools']
    print(f"    TOOLS ({len(tl)}):")
    for j, x in enumerate(tl[:a.tools]):
        print(f"      {j:3} {x['n']:22} {(x.get('a') or '')[:190]}")
    if len(tl) > a.tools:
        print(f"      ... {len(tl) - a.tools} more")
    if t['says']:
        print(f"    CLAUDE SAID: {' '.join(t['says'][0].split())[:400]}")
    if i < len(d['turns']) - 1:
        nxt = d['turns'][i + 1]
        m = mins(t['ts'], nxt['ts'])
        if m is not None:
            print(f"    -> {m} min until next Viktor turn")
