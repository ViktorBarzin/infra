#!/bin/sh
# parse-postmortem-todos.sh — Extract auto-implementable TODOs from a post-mortem markdown file
# Usage: bash scripts/parse-postmortem-todos.sh docs/post-mortems/2026-04-14-foo.md
# Output: JSON with file path and list of TODOs
#
# Supports two table formats:
#   New: | Priority | Action | Type | Details | Status |
#   Old: | Action | Status | Details |  (infers type from action text)
set -eu

PM_FILE="${1:?Usage: $0 <post-mortem.md>}"

if [ ! -f "$PM_FILE" ]; then
  echo '{"file": "", "todos": [], "error": "File not found"}' >&2
  exit 1
fi

python3 -c "
import re, json, sys

pm_file = sys.argv[1]
with open(pm_file) as f:
    content = f.read()

safe_types = {'Alert', 'Config', 'Monitor'}

todos = []

# Format 1 (new template): | Priority | Action | Type | Details | Status |
pattern_new = r'\|\s*(P[0-3])\s*\|\s*(.+?)\s*\|\s*(\w+)\s*\|\s*(.+?)\s*\|\s*TODO\s*\|'
for priority, action, todo_type, details in re.findall(pattern_new, content):
    todos.append({
        'priority': priority.strip(),
        'action': action.strip(),
        'type': todo_type.strip(),
        'details': details.strip(),
        'safe': todo_type.strip() in safe_types
    })

# Format 2 (old): | Action | TODO/Done | Details | or | Action | Owner | Status |
# Look for rows with TODO in any column
if not todos:
    pattern_old = r'\|\s*(.+?)\s*\|\s*TODO\s*\|\s*(.+?)\s*\|'
    for action, details in re.findall(pattern_old, content):
        action = action.strip()
        details = details.strip()
        # Skip header rows and clean up leading pipes
        if action.startswith('--') or action.lower() == 'action':
            continue
        action = action.lstrip('| ').strip()
        # Infer type from action text
        action_lower = action.lower()
        if any(kw in action_lower for kw in ['prometheusrule', 'alert', 'alerting']):
            todo_type = 'Alert'
        elif any(kw in action_lower for kw in ['uptime kuma', 'monitor', 'ping', 'tcp check']):
            todo_type = 'Monitor'
        elif any(kw in action_lower for kw in ['config', 'manage', 'add.*option', 'document', 'nfs.conf']):
            todo_type = 'Config'
        elif any(kw in action_lower for kw in ['migrate', 'move']):
            todo_type = 'Migration'
        elif any(kw in action_lower for kw in ['review', 'investigate', 'verify']):
            todo_type = 'Investigation'
        else:
            todo_type = 'Config'  # default to Config for ambiguous items

        # Infer priority from section header context
        priority = 'P2'  # default
        todos.append({
            'priority': priority,
            'action': action,
            'type': todo_type,
            'details': details,
            'safe': todo_type in safe_types
        })

safe_todos = [t for t in todos if t['safe']]
unsafe_todos = [t for t in todos if not t['safe']]

result = {
    'file': pm_file,
    'todos': safe_todos,
    'skipped': unsafe_todos,
    'total_todos_in_doc': len(todos),
    'safe_todos': len(safe_todos),
    'skipped_todos': len(unsafe_todos)
}

print(json.dumps(result, indent=2))
" "$PM_FILE"
