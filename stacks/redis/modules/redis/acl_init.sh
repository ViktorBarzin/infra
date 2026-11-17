#!/bin/sh
# Init container of redis-v2 (B40 R1). Redis does not start when its aclfile
# is missing, so this writes the first one from the seed (the default user,
# unchanged for clients, and acl-admin for redis-acl-sync). A file that is
# already there is kept, because redis-acl-sync owns it after the first
# minute; only its acl-admin line is replaced from the seed, so the sync can
# always log in after acl-admin's password changes or the users were
# recreated. Paths can be overridden for the offline test.
set -eu
dir=${ACL_DIR:-/data/acl}
file=$dir/users.acl
seed=${ACL_SEED:-/seed/users.acl}

grep -q '^user default ' "$seed"
admin_line=$(grep '^user acl-admin ' "$seed")
mkdir -p "$dir"
if [ -s "$file" ]; then
  { grep -v '^user acl-admin ' "$file" || true; printf '%s\n' "$admin_line"; } > "$file.init-tmp"
  echo "kept $file, refreshed its acl-admin line"
else
  cp "$seed" "$file.init-tmp"
  echo "seeded $file"
fi
mv "$file.init-tmp" "$file"
