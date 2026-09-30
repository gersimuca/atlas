"""Silver -> Gold

Turns cleaned per-document rows into the small number of business-level
aggregate tables that Athena (and the agent's query_lakehouse tool) actually
query. Keeping these separate from silver matters for two reasons: gold
tables are tiny and cheap to scan repeatedly, and they're the only thing the
agent's Lambda tool has read access to — no path from a tool call to raw
document text, by construction.
"""

import sys

from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql import functions as F

args = getResolvedOptions(sys.argv, ["JOB_NAME", "silver_database", "gold_database", "gold_table_s3_path"])

sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args["JOB_NAME"], args)

silver = spark.table(f"glue_catalog.{args['silver_database']}.documents")


def _write_gold_table(df, table_name: str, partition_cols: list[str] | None = None) -> None:
    identifier = f"glue_catalog.{args['gold_database']}.{table_name}"
    writer = df.writeTo(identifier).tableProperty("format-version", "2").tableProperty(
        "location", f"{args['gold_table_s3_path'].rstrip('/')}/{table_name}/"
    )
    if partition_cols:
        writer = writer.partitionedBy(*partition_cols)

    if spark.catalog.tableExists(identifier):
        df.writeTo(identifier).overwritePartitions() if partition_cols else df.writeTo(identifier).replace()
    else:
        writer.createOrReplace()


# --- doc_counts_by_month: volume trends per document type/department ---
doc_counts_by_month = (
    silver.groupBy("year", "month", "doc_type", "department")
    .agg(F.count("*").alias("document_count"))
    .orderBy("year", "month")
)
_write_gold_table(doc_counts_by_month, "doc_counts_by_month", partition_cols=["year"])

# --- contract_summary: one row per contract, flags likely to matter for
# "what's expiring / auto-renewing" style questions. Assumes upstream
# extraction populated these columns for doc_type='contract' rows;
# everything else is left null and simply won't appear in WHERE clauses
# filtering on them. ---
contract_summary = (
    silver.filter(F.col("doc_type") == "contract")
    .select(
        "doc_id",
        "department",
        F.col("upload_ts").alias("effective_date"),
        F.col("raw_text").contains("auto-renew").alias("has_auto_renewal_clause"),
        F.col("raw_text").contains("net 30").alias("is_net_30_terms"),
    )
)
_write_gold_table(contract_summary, "contract_summary")

# --- support_ticket_trends: ticket volume, useful for "top complaints last
# month" style questions when combined with search_knowledge_base for the
# free-text detail ---
support_ticket_trends = (
    silver.filter(F.col("doc_type") == "support_ticket")
    .groupBy("year", "month", "department")
    .agg(F.count("*").alias("ticket_count"))
    .orderBy("year", "month")
)
_write_gold_table(support_ticket_trends, "support_ticket_trends", partition_cols=["year"])

job.commit()
