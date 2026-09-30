# Architecture

This is the reasoning behind the decisions in this repo, not just a
restatement of what's in `README.md`. If you read one file before an
interview about this project, make it this one — "why" questions are where
a portfolio project actually gets tested.

## Request flow, end to end

1. A user asks a question through `api-gateway-service` (`POST /chat`),
   authenticated with a Cognito JWT.
2. `api-gateway-service` proxies to `agent-orchestrator` (`POST /invoke`) —
   an internal-only service, not reachable from outside the cluster
   (enforced by both the Helm chart having no Ingress for it, and a
   `NetworkPolicy` that only accepts traffic from `api-gateway-service`'s
   pods).
3. `agent-orchestrator` loads prior turns for this session from **AgentCore
   Memory** (if enabled), then calls **Bedrock Converse** with the
   conversation, a system prompt, and three tool specs.
4. If the model asks for a tool, the orchestrator dispatches it:
   - `search_knowledge_base` → Bedrock Knowledge Base `Retrieve` (RAG over
     document text, backed by OpenSearch Serverless)
   - `query_lakehouse` → Athena against curated gold-zone tables, **or**,
     in Gateway mode, an MCP call through **AgentCore Gateway** to a Lambda
   - `get_document_metadata` → DynamoDB, same direct/Gateway split
5. Tool results go back to the model; steps 3–4 repeat until it has enough
   to answer (capped at `max_tool_iterations`, default 5).
6. The final answer, plus a trace of every tool call made, returns to the
   user. The turn is recorded back to AgentCore Memory.

Separately, and asynchronously: documents uploaded via a presigned S3 URL
trigger an S3 event → SQS → `ingestion-worker`, which updates metadata,
kicks off the Glue crawler, and (if a classifier endpoint exists) tags the
document type. Glue ETL jobs periodically move data bronze → silver → gold.

## Why a hand-rolled agent loop instead of just using AgentCore Runtime

Bedrock AgentCore's managed Runtime can host an agent loop for you —
session isolation, long-running execution windows, no infrastructure to
run. I deliberately didn't use it for the core loop, for two reasons:

1. **The point of this project is to show the infrastructure work**, not
   abstract it away. A hand-rolled Converse + tool-use loop, containerized
   and deployed on EKS with its own autoscaling, health checks, and IAM,
   demonstrates exactly the Docker/Kubernetes/Terraform skills this repo
   exists to practice. Handing the whole loop to a managed runtime would
   make the "application layer" in the architecture diagram basically
   disappear.
2. **AgentCore's other primitives are still genuinely used** — Gateway for
   governed tool access, Memory for session continuity — because those
   solve real problems (centralized tool governance, statelessness across
   pod restarts) that would otherwise need bespoke infrastructure of their
   own. Using the managed pieces that solve a specific infra problem, while
   keeping the reasoning loop itself in code I own, is the balance a real
   team building this would likely land on too, not just a demo choice.

`docs/cost-estimate.md` and this file both flag the same underlying theme:
knowing when to build vs. reuse is itself part of the job.

## The `ToolExecutor` split: direct vs. Gateway

`agent-orchestrator/app/agent/tool_executor.py` defines one interface with
two implementations, selected by `TOOL_EXECUTION_MODE`:

- **`DirectToolExecutor`** — this container calls Athena/DynamoDB itself.
  Fewer moving parts, works great against LocalStack, is the local-dev and
  small-deployment default.
- **`GatewayToolExecutor`** — the same two operations, invoked as MCP tools
  through the AgentCore Gateway, authenticated with a Cognito
  client-credentials JWT scoped to exactly `atlas-api/tools.invoke`.

The agent's reasoning loop never knows which one is active. This is the
same shape as swapping a repository implementation behind an interface in
any other backend system — the "AI" part doesn't exempt it from ordinary
software design.

## Why EKS uses a community Terraform module but nothing else does

`infra/modules/networking`, `lakehouse`, `bedrock`, `agentcore`, `security`,
`sagemaker`, and `ecr` are all hand-written HCL. `infra/modules/eks` wraps
`terraform-aws-modules/eks/aws` instead. That's not inconsistency — it's a
judgment call: hand-rolling an EKS control plane, node groups, IRSA
plumbing, and addon version pinning from scratch is a lot of boilerplate
with little additional learning value over just reading how the community
module does it, and it's genuinely the de-facto standard in real
production Terraform. The other modules are bespoke enough to this
project's specific data/AI resources that writing them by hand is both
necessary and where the actual learning is.

## Why Fargate in dev, Karpenter-managed nodes in prod

Dev's `eks_compute_type = "fargate"` means zero idle EC2 cost while
iterating — you pay per pod-second actually scheduled, nothing while the
cluster sits idle overnight. Prod's `"managed_node_group"` (with Karpenter
handling day-2 scaling) exists because Fargate has real limits that matter
at production scale: no DaemonSets, no privileged pods, less control over
instance selection for cost-optimized spot/on-demand mixes. Karpenter
(rather than the older Cluster Autoscaler) is the current AWS-recommended
approach — it provisions right-sized nodes directly from EC2 rather than
scaling pre-defined node groups, which matters for bin-packing efficiency.

## Why Iceberg, not just partitioned Parquet

A "data lake" is object storage with files in it. A "**lakehouse**" — the
word the job spec uses deliberately — adds table semantics on top: ACID
transactions, schema evolution, time travel. Plain partitioned Parquet
gives you none of that; re-running a Glue job that writes Parquet can
easily produce duplicate or inconsistent data if it fails halfway. Both
`bronze_to_silver.py` and `silver_to_gold.py` write Iceberg tables via
Glue 4.0's native Spark integration for exactly this reason.

## Why gold, and only gold, is reachable from a tool call

`query_lakehouse` (both the direct path and the Lambda behind the Gateway)
only has IAM permissions on the **gold** zone. There's no code path — not a
missing permission, an actual absent code path — from a tool call to raw
document text in bronze/silver. Free-text/conceptual questions go through
`search_knowledge_base` instead, which reads from gold's `documents/`
prefix specifically. This is a deliberate blast-radius decision: even if a
prompt injection somehow convinced the model to try to read something it
shouldn't, the tool doesn't have the reach to do it.

## What's intentionally *not* Terraform

- **The SageMaker Pipeline** (`ml/sagemaker/pipeline/pipeline_definition.py`)
  is deployed via the SageMaker Python SDK's `.upsert()`, not a Terraform
  resource — there isn't a native `aws_sagemaker_pipeline` resource, and a
  Pipeline is fundamentally a DAG-as-code artifact, not a declarative
  infrastructure shape. Terraform's job is the scaffolding underneath it
  (the execution role, the Model Package Group); the workflow itself is
  code, deployed like code.
- **Karpenter's `NodePool`/`EC2NodeClass`** (`k8s/karpenter/*.yaml`) are
  applied via `kubectl apply`, not a Terraform `kubernetes_manifest`
  resource. These are workload-scheduling configuration that gets iterated
  on far more often than the cluster itself (instance type mixes, capacity
  splits) — keeping them out of Terraform's blast radius means changing
  them doesn't require a full `plan`/`apply` cycle.

## Testing strategy

Given the scope, tests focus on the highest-value, most failure-prone
logic rather than exhaustive coverage:
- The agent's tool-use loop, against a deterministic mock Bedrock client
  (no network, no flakiness, tests the *shape* of the ReAct loop itself).
- The SQL-safety guardrail in isolation (rejects non-`SELECT`, rejects
  statement chaining, forces a `LIMIT`) — this is the one piece of
  application code standing between an LLM's output and a database query,
  so it's the piece most worth testing in isolation.
- Basic endpoint/contract tests for the public API.

What's *not* covered: true end-to-end tests against a live cluster (would
need a real or ephemeral AWS environment per test run — a reasonable next
step, not something to fake with mocks), and load/chaos testing (see the
"what I'd add for production" list in the README).
