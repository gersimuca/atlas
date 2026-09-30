"""AgentCore Gateway target: fetches metadata for a single document by ID
from the DynamoDB document-metadata table. Deliberately the smallest
possible tool — one job, one table, one permission.
"""

import os
import boto3

METADATA_TABLE_NAME = os.environ["METADATA_TABLE_NAME"]

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(METADATA_TABLE_NAME)


def lambda_handler(event, _context):
    document_id = (event.get("document_id") or "").strip()
    if not document_id:
        return {"error": "No document_id provided."}

    response = table.get_item(Key={"document_id": document_id})
    item = response.get("Item")

    if not item:
        return {"error": f"No document found with id={document_id}."}

    return {
        "document_id": item.get("document_id"),
        "doc_type": item.get("doc_type"),
        "department": item.get("department"),
        "upload_ts": item.get("upload_ts"),
        "status": item.get("status"),
        "s3_uri": item.get("s3_uri"),
    }
