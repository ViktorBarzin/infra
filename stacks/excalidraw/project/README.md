# Excalidraw Rooms

A self-hosted Excalidraw library with per-user drawing storage and management.

## Features

- Dashboard to manage all your drawings
- Per-user storage (via Authentik SSO headers)
- Create, edit, and delete drawings
- Persistent storage via NFS

## Docker Image

```
viktorbarzin/excalidraw-library:v4
```

Available on Docker Hub: https://hub.docker.com/r/viktorbarzin/excalidraw-library

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

## Deployment

### Docker

```bash
docker run -d \
  --name excalidraw-rooms \
  -p 8080:8080 \
  -v /path/to/storage:/data \
  viktorbarzin/excalidraw-library:v4
```

### Kubernetes

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: excalidraw
spec:
  replicas: 1
  selector:
    matchLabels:
      app: excalidraw
  template:
    metadata:
      labels:
        app: excalidraw
    spec:
      containers:
        - name: excalidraw
          image: viktorbarzin/excalidraw-library:v4
          ports:
            - containerPort: 8080
          env:
            - name: DATA_DIR
              value: /data
            - name: PORT
              value: "8080"
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          nfs:
            server: 10.0.10.15
            path: /mnt/main/excalidraw
```

### With Authentik SSO

The application reads user identity from Authentik headers:

- `X-Authentik-Username` - Used to create per-user storage directories
- `X-Authentik-Email` - Displayed in UI
- `X-Authentik-Name` - Displayed in UI

Configure your ingress to pass these headers:

```yaml
annotations:
  nginx.ingress.kubernetes.io/auth-response-headers: "X-authentik-username,X-authentik-email,X-authentik-name"
```

## Building

```bash
# Build the Docker image
docker build -t excalidraw-library .

# Or build locally
go build -o excalidraw-library .
./excalidraw-library
```

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/` | Dashboard UI |
| GET | `/api/drawings` | List all drawings for current user |
| GET | `/api/drawings/:id` | Get drawing data |
| PUT | `/api/drawings/:id` | Save drawing |
| DELETE | `/api/drawings/:id` | Delete drawing |
| GET | `/api/user` | Get current user info |
| GET | `/draw/:id` | Open drawing in editor |

## License

MIT
