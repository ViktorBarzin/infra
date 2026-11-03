FROM python:3.12-slim

# ipmitool baked in (NO per-run apt — avoids the status-page-pusher IO-storm anti-pattern).
RUN apt-get update \
    && apt-get install -y --no-install-recommends ipmitool \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY fan_logic.py controller.py ./

RUN useradd -r -u 1000 fan && chown -R fan /app
USER fan

ENTRYPOINT ["python3", "controller.py"]
