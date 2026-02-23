from fastapi import FastAPI

app = FastAPI(title="F1 Streams")


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/")
async def root():
    return {"service": "f1-streams", "version": "2.0.1"}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000)
