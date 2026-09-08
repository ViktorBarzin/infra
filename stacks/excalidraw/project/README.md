# Excalidraw Rooms

A self-hosted Excalidraw library with per-user drawing storage and management.

## Features

- Dashboard to manage all your drawings (create, open, rename, delete)
- Per-user storage (via Authentik SSO headers)
- Rename drawings from the dashboard or by clicking the drawing name in the editor
- Native Excalidraw export via the editor's hamburger menu: "Save to..."
  (.excalidraw file) and "Export image..." (PNG / SVG / clipboard)
- Autosave (2s debounce) + manual save (Ctrl+S or menu "Save now")
- Persistent storage via NFS

## Docker Image

```
ghcr.io/viktorbarzin/excalidraw-library:latest
```

Built by GitHub Actions (`.github/workflows/build-excalidraw.yml` in the infra
repo, ADR-0002) on every master push touching `stacks/excalidraw/project/**`;
tags `:latest` + `:<git-sha>`. The package is PRIVATE — cluster pulls use the
Kyverno-synced `ghcr-credentials` secret. Keel polls `:latest` and rolls the
deployment on digest change.

The legacy manually-built DockerHub image `viktorbarzin/excalidraw-library:v4`
is frozen as the rollback target; nothing pushes to it anymore.

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DATA_DIR` | `/data` | Directory where drawings are stored |
| `PORT` | `8080` | HTTP server port |

### Storage

Mount a persistent volume to the `DATA_DIR` path. Drawings are stored as `.excalidraw` files, organized by username:

```
/data/
├── user1/
│   ├── drawing1.excalidraw
│   └── drawing2.excalidraw
└── user2/
    └── my-diagram.excalidraw
```

The filename (without extension) is both the drawing ID and its display name;
renaming a drawing renames the file (`os.Rename`, mtime preserved).

## Deployment

Deployed by the `stacks/excalidraw` Terraform stack (namespace `excalidraw`,
service `draw`, ingress `draw.viktorbarzin.me` with `auth = "required"`).

### With Authentik SSO

The application reads user identity from Authentik headers:

- `X-Authentik-Username` - Used to create per-user storage directories
- `X-Authentik-Email` - Displayed in UI
- `X-Authentik-Name` - Displayed in UI

Requests without `X-Authentik-Username` fall back to the `anonymous` user.

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/` | Dashboard UI |
| GET | `/api/drawings` | List all drawings for current user |
| GET | `/api/drawings/:id` | Get drawing data |
| PUT | `/api/drawings/:id` | Save drawing |
| PATCH | `/api/drawings/:id` | Rename drawing — body `{"name": "<new-name>"}`; returns `{"status":"renamed","id":"<new-id>"}`; 409 if the target name exists |
| DELETE | `/api/drawings/:id` | Delete drawing |
| GET | `/api/user` | Get current user info |
| GET | `/draw/:id` | Open drawing in editor |

Rename names are sanitized server-side to `[a-zA-Z0-9-_]` (other characters
become `-`; a trailing `.excalidraw` is stripped). Existing IDs are accepted
as-is for backward compatibility with API clients.

## Development

```bash
# Run tests
go test ./...

# Run locally
DATA_DIR=/tmp/excalidraw-data go run .
```

## License

MIT
