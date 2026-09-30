#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../local-dev"

echo "==> Building and starting the local stack..."
docker compose up --build -d

echo "==> Waiting for services to become healthy..."
for i in $(seq 1 30); do
  if curl -fsS http://localhost:8001/health >/dev/null 2>&1 && curl -fsS http://localhost:8000/health >/dev/null 2>&1; then
    echo "Both services are up."
    break
  fi
  sleep 2
  if [ "$i" -eq 30 ]; then
    echo "Services did not become healthy in time — check: docker compose logs"
    exit 1
  fi
done

echo "==> Seeding sample data..."
python3 "$(dirname "$0")/seed_sample_data.py" --endpoint-url http://localhost:4566

cat <<'EOF'

Ready:
  API docs:            http://localhost:8000/docs
  Agent docs:          http://localhost:8001/docs
  LocalStack health:   http://localhost:4566/_localstack/health

Try it:
  curl -X POST http://localhost:8000/chat -H 'Content-Type: application/json' \
       -d '{"session_id": "demo-1", "message": "What contracts do we have on file?"}'
EOF
