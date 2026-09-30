# Runbook

Quick reference for "is it working" and "why isn't it working."

## Health checks

```bash
kubectl -n atlas get pods
kubectl -n atlas rollout status deployment/api-gateway-service
kubectl -n atlas rollout status deployment/agent-orchestrator

kubectl -n atlas port-forward svc/api-gateway-service 8000:8000 &
curl http://localhost:8000/health
curl http://localhost:8000/ready
```

Locally: `make local-up` then the same curls against `localhost:8000`.

## "The agent gives the [MOCK MODE] answer in a real environment"

`USE_MOCK_LLM` is still `true`. Check the ConfigMap:

```bash
kubectl -n atlas get configmap atlas-config -o jsonpath='{.data.USE_MOCK_LLM}'
```

Flip it via `values-<env>.yaml`, and confirm Bedrock model access is
actually enabled for your account/region (Bedrock console → Model access —
this is an explicit opt-in AWS doesn't turn on for you, and Terraform can't
do it either).

## "query_lakehouse always errors"

Three usual causes, in order of likelihood:
1. **Local dev**: expected — LocalStack Community's Athena/Glue support is
   partial. See `local-dev/docker-compose.yml`'s header comment.
   query_lakehouse is not part of the mock-mode happy path.
   1. **The SQL got rejected by the guardrail regex**: check the tool's
      `error` field — only single `SELECT` statements are allowed, no
      semicolons/chained statements. This is enforced deliberately.
2. **Athena query failed on AWS**: `aws athena get-query-execution
   --query-execution-id <id>` to see the actual failure reason — usually a
   Glue Data Catalog table that doesn't exist yet (gold zone hasn't been
   populated by `silver_to_gold.py` for the table being queried).

## "The Gateway tool calls fail with 401/403" (gateway mode only)

- Confirm `TOOL_EXECUTION_MODE=gateway` and the Secrets Manager secret
  (`agent_m2m_credentials`) actually contains a valid `client_id` /
  `client_secret` / `token_url` / `gateway_url`.
- The Cognito M2M client's allowed scope must include
  `atlas-api/tools.invoke` — this is set by Terraform
  (`infra/modules/security`), but double-check if you've hand-edited
  anything in Cognito directly.

## "New pods stuck Pending"

- **Fargate (dev)**: check the Fargate profile's namespace selector
  (`infra/modules/eks`) actually matches the pod's namespace (`atlas`).
- **Managed node group / Karpenter (prod)**: `kubectl get nodeclaims` and
  `kubectl describe nodepool atlas-prod-default` — usually an instance-type
  or subnet-tag mismatch between the NodePool/EC2NodeClass
  (`k8s/karpenter/`) and what Terraform actually tagged.

## "Ingestion worker isn't picking up new documents"

```bash
kubectl -n atlas logs deployment/ingestion-worker --tail=100
aws sqs get-queue-attributes --queue-url <queue-url> \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible
```

If messages are piling up in the dead-letter queue
(`atlas-<env>-ingestion-dlq`), something in `_handle_s3_record` is throwing
— check the DLQ messages' contents against the worker's logs from around
that time.

## Rolling back a bad deploy

```bash
helm -n atlas history atlas
helm -n atlas rollback atlas <revision>
```

## Full teardown

```bash
cd infra/environments/<env>
terraform destroy
```

See `docs/cost-estimate.md` for what specifically to double-check didn't
get orphaned (OpenSearch Serverless collection, in particular).
