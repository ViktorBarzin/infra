#!/usr/bin/env python3
"""Per-session digest: every HUMAN turn + the tool sequence that followed it,
+ which memories the recall hook injected for that turn, + compaction points.

Substrate for D1 (correction language), D2 (tool-sequence anomaly),
D3 (memory-recall efficacy), D4 (wins control). Agents read these digests,
never the 622 MB of raw jsonl.

Two extraction facts learned the hard way, both verified against raw lines:
  * memory injections are NOT user messages. They are `type:"attachment"`
    entries whose `attachment.type == "hook_additional_context"`, carrying a
    `content` list of strings. A first pass that only read `"message"` lines
    reported 0 recall injections corpus-wide, which contradicted
    `homelab usage top` (1,820 recall calls / 30d). 494 real injections exist.
  * harness-injected user-role entries (skill bodies, compaction summaries,
    teammate messages) are not turns Viktor typed; counting them inflated the
    first pass from 1,381 to 1,861.
"""
import json, os, glob, re

HERE = os.getcwd()
OUTDIR = os.path.join(HERE, 'digests')
os.makedirs(OUTDIR, exist_ok=True)

HOOK_MEM = 'Relevant stored memories'
MEM_ID = re.compile(r'#(\d+) \[([a-z]+)\] \(([\d.]+)\)')

INJECTED = re.compile(
    r'(Base directory for this skill:)'
    r'|(This session is being continued from a previous conversation)'
    r'|(Another Claude session sent a message:)'
    r'|(^# Workflow authoring reference)'
    r'|(^<)'
    r'|(Caveat: The messages below were generated)'
    r'|(^\[Request interrupted)'
    r'|(^\[terminal-lobby\])'
    r'|(^Interview (me|the user) relentlessly)',
    re.I)

def txt(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return ' '.join(p.get('text', '') for p in content
                        if isinstance(p, dict) and p.get('type') == 'text')
    return ''

def arg_sketch(inp):
    if not isinstance(inp, dict):
        return ''
    for k in ('command', 'file_path', 'pattern', 'query', 'url', 'prompt',
              'skill', 'description'):
        v = inp.get(k)
        if isinstance(v, str) and v.strip():
            return f'{k}={v.strip()[:400]}'
    return ','.join(list(inp.keys())[:5])

def build(path):
    events = []
    with open(path, errors='replace') as fh:
        for lineno, line in enumerate(fh, 1):
            try:
                d = json.loads(line)
            except Exception:
                continue
            ts = d.get('timestamp')
            etype = d.get('type')

            if etype == 'attachment':
                a = d.get('attachment') or {}
                if a.get('type') == 'hook_additional_context':
                    blob = '\n'.join(x for x in (a.get('content') or [])
                                     if isinstance(x, str))
                    if HOOK_MEM in blob:
                        events.append({'k': 'mem', 'line': lineno, 'ts': ts,
                                       'mems': [{'id': i, 'cat': c, 'score': float(s)}
                                                for i, c, s in MEM_ID.findall(blob)]})
                elif a.get('type') == 'compact_file_reference':
                    events.append({'k': 'compact', 'line': lineno, 'ts': ts})
                continue

            m = d.get('message') or {}
            role = m.get('role')
            if role == 'user':
                t = txt(m.get('content')).strip()
                if not t:
                    continue
                events.append({'k': 'user', 'line': lineno, 'ts': ts, 'text': t,
                               'injected': bool(INJECTED.match(t))})
            elif role == 'assistant':
                c = m.get('content')
                if not isinstance(c, list):
                    continue
                for p in c:
                    if not isinstance(p, dict):
                        continue
                    if p.get('type') == 'tool_use':
                        events.append({'k': 'tool', 'line': lineno, 'ts': ts,
                                       'name': p.get('name'),
                                       'arg': arg_sketch(p.get('input'))})
                    elif p.get('type') == 'text' and (p.get('text') or '').strip():
                        events.append({'k': 'say', 'line': lineno, 'ts': ts,
                                       'text': p['text'].strip()[:600]})

    turns, cur, pending_mems = [], None, []
    for e in events:
        if e['k'] == 'mem':
            # VERIFIED against raw jsonl (48a6e6d8, lines 2981/2984): the
            # hook_additional_context attachment is written ~2s AFTER the user
            # message it was computed for, so it belongs to the turn ALREADY
            # OPEN, not the next one. Attaching it forward shifted every
            # attribution one turn late and produced a wrong timeline.
            if cur is not None:
                cur['recalled'].extend(e['mems'])
            else:
                pending_mems.extend(e['mems'])
        elif e['k'] == 'compact':
            if cur is not None:
                cur['compacted_after'] = True
        elif e['k'] == 'user':
            if e['text'].startswith('[Request interrupted') and cur is not None:
                cur['interrupted'] = True
                continue
            if e['injected']:
                continue
            cur = {'line': e['line'], 'ts': e['ts'], 'prompt': e['text'][:4000],
                   'prompt_len': len(e['text']), 'tools': [], 'says': [],
                   'recalled': pending_mems, 'interrupted': False,
                   'compacted_after': False}
            pending_mems = []
            turns.append(cur)
        elif cur is not None:
            if e['k'] == 'tool':
                cur['tools'].append({'n': e['name'], 'a': e['arg'], 'ts': e['ts']})
            else:
                cur['says'].append(e['text'])
    return turns

inv = json.load(open(os.path.join(HERE, 'inventory.json')))
real = [s for s in inv if not s['synthetic'] and s['human_turns'] > 0]
manifest = []
for s in real:
    if not os.path.exists(s['path']):
        continue  # transcript rotated away since inventory was built
    turns = build(s['path'])
    if not turns:
        continue
    rec = {'session': s['session'], 'project': s['project'], 'path': s['path'],
           'first_ts': s['first_ts'], 'last_ts': s['last_ts'],
           'n_turns': len(turns), 'turns': turns}
    out = os.path.join(OUTDIR, f"{s['project']}__{s['session']}.json")
    json.dump(rec, open(out, 'w'), indent=1)
    manifest.append({'digest': out, 'session': s['session'], 'project': s['project'],
                     'n_turns': len(turns), 'first_ts': s['first_ts'],
                     'last_ts': s['last_ts'],
                     'n_tools': sum(len(t['tools']) for t in turns),
                     'n_recalled': sum(len(t['recalled']) for t in turns),
                     'raw': s['path'], 'digest_bytes': os.path.getsize(out)})

json.dump(manifest, open(os.path.join(HERE, 'manifest.json'), 'w'), indent=1)
print(f"digests written   {len(manifest)}")
print(f"human turns       {sum(m['n_turns'] for m in manifest):,}")
print(f"tool calls        {sum(m['n_tools'] for m in manifest):,}")
print(f"memories injected {sum(m['n_recalled'] for m in manifest):,}")
print(f"turns w/ recall   {sum(1 for m in manifest for _ in [0] if m['n_recalled'])}")
print(f"digest total      {sum(m['digest_bytes'] for m in manifest)/1e6:.1f} MB")
