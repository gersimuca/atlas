# syntax=docker/dockerfile:1
FROM python:3.12-slim AS builder

WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --user -r requirements.txt

FROM python:3.12-slim

RUN useradd --create-home --uid 1000 --shell /usr/sbin/nologin appuser

WORKDIR /app
COPY --from=builder /root/.local /home/appuser/.local
COPY app ./app

ENV PATH=/home/appuser/.local/bin:$PATH \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

USER appuser

# No HTTP port — this is a queue consumer, not a web service. Kubernetes
# liveness is handled via a small file-touch heartbeat (see worker.py)
# checked with an exec probe rather than an HTTP one.
CMD ["python", "-m", "app.worker"]
