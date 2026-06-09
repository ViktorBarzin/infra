# GitHub API Reference

> Token locations and common API patterns.

## GitHub API
- **Username**: `ViktorBarzin`
- **Token**: `grep github_pat terraform.tfvars | cut -d'"' -f2` (git-crypt encrypted)
- **Scopes**: Full access (repo, admin:public_key, admin:repo_hook, delete_repo, admin:org, workflow, write:packages)
- **`gh` CLI**: Blocked by sandbox — use `curl` instead

```bash
GITHUB_TOKEN=$(grep github_pat terraform.tfvars | cut -d'"' -f2)

# List repos
curl -s -H "Authorization: token $GITHUB_TOKEN" "https://api.github.com/users/ViktorBarzin/repos?per_page=100"

# Create repo
curl -s -X POST -H "Authorization: token $GITHUB_TOKEN" "https://api.github.com/user/repos" \
  -d '{"name":"repo-name","private":true}'

# Add deploy key
curl -s -X POST -H "Authorization: token $GITHUB_TOKEN" "https://api.github.com/repos/ViktorBarzin/<repo>/keys" \
  -d '{"title":"key-name","key":"ssh-ed25519 ...","read_only":false}'

# Create webhook
curl -s -X POST -H "Authorization: token $GITHUB_TOKEN" "https://api.github.com/repos/ViktorBarzin/<repo>/hooks" \
  -d '{"config":{"url":"https://ci.viktorbarzin.me/hook","content_type":"json","secret":"..."},"events":["push","pull_request"]}'
```

## Capabilities
- **GitHub**: Create/delete repos, push code, manage SSH/deploy keys, manage webhooks, manage org settings, manage packages
