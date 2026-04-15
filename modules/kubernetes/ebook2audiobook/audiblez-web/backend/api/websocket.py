from fastapi import WebSocket, WebSocketDisconnect, HTTPException
from services.converter import job_manager
from models.schemas import JobProgress
from api.auth import sanitize_user_id


class ConnectionManager:
    """Manages WebSocket connections for job progress updates."""

    def __init__(self):
        self.active_connections: dict[str, list[WebSocket]] = {}

    async def connect(self, job_id: str, websocket: WebSocket):
        """Connect a websocket for a specific job."""
        await websocket.accept()

        if job_id not in self.active_connections:
            self.active_connections[job_id] = []
        self.active_connections[job_id].append(websocket)

    def disconnect(self, job_id: str, websocket: WebSocket):
        """Disconnect a websocket."""
        if job_id in self.active_connections:
            if websocket in self.active_connections[job_id]:
                self.active_connections[job_id].remove(websocket)
            if not self.active_connections[job_id]:
                del self.active_connections[job_id]

    async def send_progress(self, job_id: str, progress: JobProgress):
        """Send progress update to all connected clients for a job."""
        if job_id in self.active_connections:
            disconnected = []
            for connection in self.active_connections[job_id]:
                try:
                    await connection.send_json(progress.model_dump())
                except:
                    disconnected.append(connection)

            # Remove disconnected clients
            for conn in disconnected:
                self.disconnect(job_id, conn)


manager = ConnectionManager()


def get_user_from_websocket(websocket: WebSocket) -> str | None:
    """
    Extract user ID from websocket headers.
    WebSocket connections receive HTTP headers during the upgrade handshake.
    """
    # Try various header name formats
    uid = websocket.headers.get("x-authentik-uid")
    if not uid:
        uid = websocket.headers.get("X-Authentik-Uid")
    if not uid:
        uid = websocket.headers.get("x-authentik-userid")
    if not uid:
        uid = websocket.headers.get("remote-user")

    if uid:
        try:
            return sanitize_user_id(uid)
        except ValueError:
            return None
    return None


async def websocket_endpoint(websocket: WebSocket, job_id: str):
    """WebSocket endpoint for job progress updates."""
    # Extract user from headers
    user_id = get_user_from_websocket(websocket)

    # Verify job exists and user has access
    job = job_manager.get_job(job_id, user_id)
    if not job:
        # Close connection if job not found or not owned by user
        await websocket.close(code=4004, reason="Job not found or access denied")
        return

    await manager.connect(job_id, websocket)

    # Register progress callback
    async def progress_callback(progress: JobProgress):
        await manager.send_progress(job_id, progress)

    job_manager.register_progress_callback(job_id, progress_callback)

    try:
        # Send initial status
        await websocket.send_json({
            "progress": job.progress,
            "status": job.status,
        })

        # Wait for messages (keep-alive)
        while True:
            await websocket.receive_text()
    except WebSocketDisconnect:
        manager.disconnect(job_id, websocket)
        job_manager.unregister_progress_callback(job_id, progress_callback)
