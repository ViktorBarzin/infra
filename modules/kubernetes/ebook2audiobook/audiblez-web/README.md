# Audiblez Web UI

Web interface for converting EPUB files to audiobooks using [audiblez](https://github.com/santinic/audiblez).

<img width="1702" height="1145" alt="image" src="https://github.com/user-attachments/assets/ba0f9090-a8e9-4550-9c9b-473058f19cbb" />

## Features

- Upload EPUB files via drag & drop
- Select from 50+ voices across multiple languages
- Preview voice samples before converting
- Real-time progress updates via WebSocket
- Download completed audiobooks

## Development

### Backend

```bash
cd backend
pip install -r requirements.txt
uvicorn main:app --reload
```

### Frontend

```bash
cd frontend
npm install
npm run dev
```

### Voice Samples

Generate voice samples (requires audiblez environment):

```bash
python generate_samples.py samples/
```

## Docker Build

```bash
docker build -t audiblez-web .
docker run -p 8000:8000 -v /path/to/data:/mnt audiblez-web
```

## Deployment

Deployed to Kubernetes via Terraform. The service mounts NFS storage at `/mnt` for:
- `/mnt/uploads` - Uploaded EPUB files
- `/mnt/outputs` - Generated audiobooks
