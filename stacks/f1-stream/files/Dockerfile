## Stage 1: Build frontend
FROM node:22-slim AS frontend-builder

WORKDIR /frontend

COPY frontend/package.json frontend/package-lock.json* ./
RUN npm install

COPY frontend/ ./
RUN npm run build

## Stage 2: Python backend + static frontend
FROM python:3.13-slim-bookworm

WORKDIR /app

# Headless Chromium runtime libs for the playback verifier. Listed inline
# (instead of running `playwright install-deps`) so the image build doesn't
# need root-network apt fetches at runtime.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libnss3 libnspr4 \
    libatk1.0-0 libatk-bridge2.0-0 libcups2 \
    libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 \
    libxfixes3 libxrandr2 libgbm1 libpango-1.0-0 libcairo2 \
    libasound2 libatspi2.0-0 \
    fonts-liberation fonts-noto-color-emoji \
 && rm -rf /var/lib/apt/lists/*

COPY backend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Install the Chromium browser binary used by the verifier. Skip
# --with-deps because we already installed the system libs above.
RUN playwright install chromium

COPY backend/ ./backend/

# Copy built frontend into the image
COPY --from=frontend-builder /frontend/build ./frontend/build

EXPOSE 8000

CMD ["uvicorn", "backend.main:app", "--host", "0.0.0.0", "--port", "8000"]
