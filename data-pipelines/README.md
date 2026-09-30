# Data pipelines

Medallion architecture, three zones, all Iceberg tables in the Glue Data
Catalog:

| Zone | Contents | Written by |
|---|---|---|
| **bronze** | Raw documents as landed (one row per upload, already text-extracted upstream) | ingestion-worker + the bronze Glue crawler |
| **silver** | Cleaned, deduplicated, typed | `glue-jobs/bronze_to_silver.py` |
| **gold** | Small business-level aggregates (doc counts, contract summary, ticket trends) | `glue-jobs/silver_to_gold.py` |

Only gold is reachable from the agent's `query_lakehouse` tool — there's no
path from a tool call to raw document text, by construction. Free-text
questions go through `search_knowledge_base` (Bedrock Knowledge Base) instead.

## How these get deployed

Terraform (`infra/modules/lakehouse`) uploads both scripts to the
`glue-scripts` S3 bucket and points an `aws_glue_job` resource at each one —
so `terraform apply` always deploys whatever's checked into this folder.
There's no separate manual upload step.

## Running a job manually (outside its schedule)

```bash
aws glue start-job-run --job-name atlas-dev-bronze-to-silver
aws glue start-job-run --job-name atlas-dev-silver-to-gold
aws glue get-job-run --job-name atlas-dev-bronze-to-silver --run-id <id-from-above>
```

## Local testing

These scripts use `awsglue`, which only exists inside AWS Glue's runtime —
you can't `pip install` your way to running them locally as-is. For local
iteration, either:
- Extract the Spark logic into a plain-PySpark function and unit-test that
  directly (no `awsglue` imports) before wrapping it for Glue, or
- Use the `amazon/aws-glue-libs` Docker image, which bundles a local
  Glue-compatible Spark environment for exactly this purpose.
