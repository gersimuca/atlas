"""AgentCore Gateway target: runs a read-only SQL query against the gold-zone
lakehouse tables via Athena.

Deliberately paranoid about what SQL it will run, because this function is
reachable (indirectly, via the Gateway's JWT authorizer) from an LLM's tool
call — the model's output is untrusted input, same as a user-submitted form.
"""

import os
import re
import time
import boto3

ATHENA_DATABASE = os.environ["GLUE_DATABASE"]
ATHENA_WORKGROUP = os.environ["ATHENA_WORKGROUP"]
ATHENA_OUTPUT_S3_URI = os.environ["ATHENA_OUTPUT_S3_URI"]

MAX_WAIT_SECONDS = 25
MAX_ROWS = 100

# Anything beyond a plain SELECT is refused outright, regardless of how the
# prompt that produced it was phrased.
FORBIDDEN_KEYWORDS = re.compile(
    r"\b(insert|update|delete|drop|alter|create|grant|revoke|truncate|merge|"
    r"copy|unload|vacuum|call|--|;)\b",
    re.IGNORECASE,
)

athena = boto3.client("athena")


def lambda_handler(event, _context):
    sql = (event.get("sql") or "").strip()

    if not sql:
        return {"error": "No SQL statement provided."}
    if not sql.lower().startswith("select"):
        return {"error": "Only single SELECT statements are permitted."}
    if FORBIDDEN_KEYWORDS.search(sql):
        return {"error": "Query contains a disallowed keyword or statement separator."}
    if "limit" not in sql.lower():
        sql = f"{sql.rstrip(';')} LIMIT {MAX_ROWS}"

    try:
        execution = athena.start_query_execution(
            QueryString=sql,
            QueryExecutionContext={"Database": ATHENA_DATABASE},
            ResultConfiguration={"OutputLocation": ATHENA_OUTPUT_S3_URI},
            WorkGroup=ATHENA_WORKGROUP,
        )
    except athena.exceptions.ClientError as exc:
        return {"error": f"Athena rejected the query: {exc}"}

    query_execution_id = execution["QueryExecutionId"]
    status = "RUNNING"
    waited = 0
    while waited < MAX_WAIT_SECONDS:
        status = athena.get_query_execution(QueryExecutionId=query_execution_id)[
            "QueryExecution"
        ]["Status"]["State"]
        if status in ("SUCCEEDED", "FAILED", "CANCELLED"):
            break
        time.sleep(1)
        waited += 1

    if status != "SUCCEEDED":
        return {"error": f"Query did not complete in time (status={status})."}

    results = athena.get_query_results(
        QueryExecutionId=query_execution_id, MaxResults=MAX_ROWS
    )
    rows = results["ResultSet"]["Rows"]
    if not rows:
        return {"columns": [], "rows": []}

    columns = [c.get("VarCharValue", "") for c in rows[0]["Data"]]
    data_rows = []
    for row in rows[1:]:
        values = [cell.get("VarCharValue", "") for cell in row["Data"]]
        data_rows.append(dict(zip(columns, values)))

    return {"columns": columns, "rows": data_rows, "row_count": len(data_rows)}
