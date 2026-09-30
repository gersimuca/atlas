"""Bronze -> Silver

Reads the raw document records catalogued by the bronze crawler (one row per
uploaded document: doc_id, doc_type, department, upload_ts, raw_text, s3_uri —
raw_text is assumed already extracted upstream, e.g. by Textract, before
landing in bronze), cleans and deduplicates them, and writes the result as an
Iceberg table in the silver zone.

Iceberg (rather than plain partitioned Parquet) is deliberate: it gives ACID
writes, schema evolution, and time travel on a zone that gets re-run
regularly — exactly the properties that turn "a bunch of Parquet files" into
an actual lakehouse table.

Deployed by Terraform (infra/modules/lakehouse) as a Glue job resource; this
file is the --script-location it points at.
"""

import sys

from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql import functions as F
from pyspark.sql.window import Window

args = getResolvedOptions(
    sys.argv,
    ["JOB_NAME", "bronze_database", "bronze_table", "silver_database", "silver_table_s3_path"],
)

sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args["JOB_NAME"], args)

# --- Read raw documents metadata from the bronze Glue Catalog table ---
bronze_dyf = glueContext.create_dynamic_frame.from_catalog(
    database=args["bronze_database"],
    table_name=args.get("bronze_table", "documents"),
    transformation_ctx="bronze_source",
)
df = bronze_dyf.toDF()

# --- Clean & validate ---
cleaned = (
    df.filter(F.col("doc_id").isNotNull() & F.col("raw_text").isNotNull())
    .withColumn("doc_type", F.lower(F.trim(F.col("doc_type"))))
    .withColumn("department", F.trim(F.col("department")))
    .withColumn("upload_ts", F.to_timestamp("upload_ts"))
    .withColumn("year", F.year("upload_ts"))
    .withColumn("month", F.month("upload_ts"))
    .withColumn("text_length", F.length("raw_text"))
    .filter(F.col("text_length") > 0)
)

# --- De-duplicate: a document can be re-uploaded (corrections, re-scans);
# keep only the most recently uploaded version of each doc_id. ---
dedup_window = Window.partitionBy("doc_id").orderBy(F.col("upload_ts").desc())
deduped = (
    cleaned.withColumn("row_num", F.row_number().over(dedup_window))
    .filter(F.col("row_num") == 1)
    .drop("row_num", "text_length")
    .withColumn("processed_at", F.current_timestamp())
)

# --- Write to the silver zone as an Iceberg table (requires the job's
# --datalake-formats=iceberg argument, set in the Terraform aws_glue_job
# resource's default_arguments) ---
table_identifier = f"glue_catalog.{args['silver_database']}.documents"

if spark.catalog.tableExists(table_identifier):
    deduped.writeTo(table_identifier).overwritePartitions()
else:
    (
        deduped.writeTo(table_identifier)
        .tableProperty("format-version", "2")
        .tableProperty("location", args["silver_table_s3_path"])
        .partitionedBy("doc_type", "year", "month")
        .createOrReplace()
    )

job.commit()
