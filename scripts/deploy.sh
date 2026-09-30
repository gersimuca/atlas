#!/usr/bin/env bash
# Manual equivalent of .github/workflows/deploy.yml, for deploying from
# your own machine (e.g. testing a change before pushing) rather than
# waiting on CI. Real deploys should go through the pipeline so they're
# reviewed, tested, and auditable — this is a convenience, not the primary
# path.
set -euo pipefail

ENV="${1:-dev}"
AWS_REGION="${AWS_REGION:-us-east-1}"
GIT_SHA=$(git rev-parse --short HEAD)

echo "==> Deploying to ${ENV} (tag: ${GIT_SHA})"

ECR_REGISTRY=$(aws sts get-caller-identity --query Account --output text).dkr.ecr.${AWS_REGION}.amazonaws.com
aws ecr get-login-password --region "${AWS_REGION}" | docker login --username AWS --password-stdin "${ECR_REGISTRY}"

for svc in api-gateway-service agent-orchestrator ingestion-worker; do
  echo "==> Building ${svc}"
  docker build -t "${ECR_REGISTRY}/atlas/${svc}:${GIT_SHA}" "apps/${svc}"
  docker push "${ECR_REGISTRY}/atlas/${svc}:${GIT_SHA}"
done

aws eks update-kubeconfig --name "atlas-${ENV}" --region "${AWS_REGION}"

helm upgrade --install atlas k8s/helm/atlas-platform \
  --namespace atlas --create-namespace \
  -f "k8s/helm/atlas-platform/values.yaml" \
  -f "k8s/helm/atlas-platform/values-${ENV}.yaml" \
  --set image.registry="${ECR_REGISTRY}" \
  --set image.tag="${GIT_SHA}" \
  --wait --timeout 5m

echo "==> Done. Rollout status:"
kubectl -n atlas rollout status deployment/api-gateway-service
kubectl -n atlas rollout status deployment/agent-orchestrator
