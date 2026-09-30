# Cost notes

Rough, order-of-magnitude figures for `us-east-1`, meant to set expectations
before you `terraform apply` — not a quote. Check current pricing pages for
anything you're about to leave running for a while.

## The one that actually matters: OpenSearch Serverless

The Bedrock Knowledge Base's vector store (`infra/modules/bedrock`) defaults
to **Amazon OpenSearch Serverless**, which bills a minimum OCU floor
**whether or not you query it** — commonly cited around **$350+/month**
just sitting idle. This is the single biggest cost trap in this repo.

Two ways to avoid it:
1. **Tear down when you're not using it** (see below) — the collection is a
   normal Terraform-managed resource, so `terraform destroy` removes it
   along with everything else.
2. **Migrate to Amazon S3 Vectors** — AWS's cost-optimized vector store
   option added in late 2025, pay-as-you-go with no idle floor, natively
   supported as a Bedrock Knowledge Base backend. The `bedrock` module has
   a `vector_store_type` variable for this; the OpenSearch path is what's
   fully implemented here since its Terraform schema is the more
   battle-tested one, but for a project this size, S3 Vectors is very
   likely the better default in practice — see that variable's docstring.

**Gotcha:** deleting a Knowledge Base via the console does **not** delete
its OpenSearch Serverless collection. `terraform destroy` handles this
correctly since Terraform tracks both resources — deleting either one by
hand outside Terraform is how people end up with an orphaned collection
still billing a month later.

## Everything else, roughly

| Resource | Idle cost | Notes |
|---|---|---|
| EKS control plane | ~$73/mo flat | Per cluster, regardless of usage |
| EKS compute (dev: Fargate) | ~$0 idle | Pay per pod-second actually running |
| EKS compute (prod: managed nodes + Karpenter) | scales with load | `terraform.tfvars` sizing is a starting point, not a target |
| NAT Gateway | ~$32/mo per gateway + data | Dev uses one shared gateway; prod uses one per AZ |
| S3 (all zones) | pennies at this scale | Storage is cheap; egress and requests rarely aren't |
| Glue jobs | $0 idle | Billed per DPU-hour only while a job runs |
| Athena | $0 idle | Billed per TB scanned — the workgroup's 5 GB/query cap is a guardrail, not just a number |
| Bedrock (Converse, embeddings) | $0 idle | Per-token, pay as you go |
| Bedrock Guardrails | $0 idle | Per text unit processed |
| AgentCore Gateway / Memory | $0 idle (mostly) | Check current AgentCore pricing — it's billed separately from model tokens |
| SageMaker training/processing | $0 idle | Per instance-second while a job runs |
| SageMaker Studio domain | $0 idle if `enable_studio_domain=false` | Off by default in this repo for exactly this reason |
| Secrets Manager | ~$0.40/secret/mo | Trivial at this scale |
| DynamoDB, SQS | ~$0 at low volume | Pay-per-request billing mode |

## Design choices made specifically for cost

- **Fargate for dev EKS compute** — no idle EC2 node cost while iterating;
  only pay for pods actually scheduled.
- **Single NAT gateway in dev**, one per AZ only in prod — HA costs money,
  and dev doesn't need it.
- **SageMaker Studio off by default** — turn it on
  (`enable_sagemaker_studio = true`) only when you're actually doing
  interactive EDA; the training pipeline itself never needs it.
- **Athena workgroup byte-scan cap** — a runaway or malformed query from
  the agent can't scan an unbounded amount of data.
- **ECR lifecycle policies** — old images expire automatically instead of
  accumulating storage cost forever.

## Tear down when you're done

```bash
cd infra/environments/dev
terraform destroy
```

Do this after every demo session unless you're actively using the
environment. Nothing in this stack needs to run 24/7 for a portfolio project.
