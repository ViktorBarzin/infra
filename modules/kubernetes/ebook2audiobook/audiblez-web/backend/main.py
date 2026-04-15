from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles
from fastapi.middleware.cors import CORSMiddleware
from pathlib import Path

from api.routes import router
from api.websocket import websocket_endpoint

app = FastAPI(title="Audiblez Web API", version="1.0.0")

# CORS middleware for development
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Health check - must be before static mount
@app.get("/health")
async def health_check():
    return {"status": "healthy"}

# Include API routes
app.include_router(router)

# WebSocket endpoint
@app.websocket("/ws/jobs/{job_id}")
async def websocket_route(websocket, job_id: str):
    await websocket_endpoint(websocket, job_id)

# Serve static frontend files - MUST BE LAST as it catches all routes
static_dir = Path("/app/frontend/dist")
if static_dir.exists():
    app.mount("/", StaticFiles(directory=str(static_dir), html=True), name="static")


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
