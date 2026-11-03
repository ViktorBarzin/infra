#!/usr/bin/env python3
"""Mine Viktor's ACTUAL correction vocabulary from the 1,861 real prompts."""
import json, glob, re, collections
prompts = []
for f in glob.glob('digests/*.json'):
    d = json.load(open(f))
    for i, t in enumerate(d['turns']):
        prompts.append((d['session'], d['project'], i, t['prompt']))
print(f"prompts: {len(prompts)}")

# broad candidate net, deliberately over-inclusive; I read the hits myself
NET = re.compile(r"""
 (you \s (should|could|must|need|forgot|missed|didn't|did \s not|already))
|(why \s (did|are|aren't|didn't|do) \s you)
|(instead \s of)
|(i \s (told|said|asked) \s you)
|(we \s (have|already \s have|use|self-?host))
|(use \s the \s \w+ \s (instead|for))
|(no[,.\s]+(use|we|that|i|it|don't))
|(don'?t \s (use|do|write|build|create|reinvent))
|(there'?s \s already)
|(already \s (exists|have|there|running|built))
|(that'?s \s (wrong|not|the \s wrong))
|(stop\b)
|(wrong \s (tool|approach|way|path))
|(this \s is \s (wrong|not))
|(you \s (know|knew) \s this)
|(should \s (have )?know)
|(read \s the \s (rules|claude\.md|docs))
|(check \s homelab)
|(homelab \s \w+)
""", re.I | re.X)

hits = [(s, p, i, t) for s, p, i, t in prompts if NET.search(t)]
print(f"candidate corrections: {len(hits)}  ({100*len(hits)/len(prompts):.0f}%)\n")
for s, p, i, t in hits[:80]:
    one = ' '.join(t.split())
    print(f"[{p[:28]:28} t{i:<3}] {one[:190]}")
