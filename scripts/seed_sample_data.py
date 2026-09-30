"""Uploads a handful of synthetic sample documents directly to the bronze
bucket via boto3 — unlike the LocalStack init script's direct DynamoDB
inserts, this goes through the real path: S3 upload -> S3 event -> SQS ->
ingestion-worker -> DynamoDB update. Useful both for local demos and for
populating a freshly-deployed real dev environment with something to query.
"""

import argparse
import uuid
from datetime import datetime, timezone

import boto3

SAMPLE_DOCUMENTS = [
    {
        "doc_type": "contract",
        "department": "procurement",
        "file_name": "cloud-hosting-msa.txt",
        "text": (
            "MASTER SERVICE AGREEMENT\n\n"
            "This agreement is effective as of 2026-01-15 between Atlas Corp and Northwind Cloud Services.\n"
            "Term: 24 months, with auto-renewal for successive 12-month periods unless either party gives "
            "90 days' written notice of non-renewal.\n"
            "Payment terms: Net 30 from invoice date.\n"
            "This agreement expires 2028-01-14 absent non-renewal notice.\n"
        ),
    },
    {
        "doc_type": "contract",
        "department": "facilities",
        "file_name": "office-lease-tirana.txt",
        "text": (
            "COMMERCIAL LEASE AGREEMENT\n\n"
            "Premises: Tirana central office, effective 2025-09-01.\n"
            "Term: 36 months. No automatic renewal — requires a new agreement at term end.\n"
            "Payment terms: Net 15, due on the 1st of each month.\n"
        ),
    },
    {
        "doc_type": "invoice",
        "department": "finance",
        "file_name": "invoice-2026-0447.txt",
        "text": (
            "INVOICE #2026-0447\nVendor: Northwind Cloud Services\nAmount: $18,400.00\n"
            "Issued: 2026-06-01. Due: 2026-07-01 (Net 30). Status: Paid on 2026-06-28.\n"
        ),
    },
    {
        "doc_type": "support_ticket",
        "department": "customer-success",
        "file_name": "ticket-4471.txt",
        "text": (
            "TICKET #4471 — Priority: High\n"
            "Customer reports intermittent 502 errors on the reporting dashboard during peak hours. "
            "Support engineer found the upstream API gateway was hitting connection pool limits under load.\n"
            "Resolution: increased pool size and added a queue-based backpressure mechanism.\n"
        ),
    },
    {
        "doc_type": "report",
        "department": "operations",
        "file_name": "q2-2026-uptime-report.txt",
        "text": (
            "Q2 2026 OPERATIONS REPORT\n"
            "Platform uptime: 99.94%. Two incidents, both resolved within SLA. "
            "Support ticket volume up 12% quarter-over-quarter, concentrated in the reporting dashboard area.\n"
        ),
    },
]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint-url", default=None, help="Set for LocalStack, e.g. http://localhost:4566")
    parser.add_argument("--bucket", default="atlas-local-bronze")
    parser.add_argument("--table", default="atlas-local-document-metadata")
    parser.add_argument("--region", default="us-east-1")
    args = parser.parse_args()

    client_kwargs = {"region_name": args.region}
    if args.endpoint_url:
        client_kwargs["endpoint_url"] = args.endpoint_url

    s3 = boto3.client("s3", **client_kwargs)
    dynamodb = boto3.resource("dynamodb", **client_kwargs).Table(args.table)

    for doc in SAMPLE_DOCUMENTS:
        document_id = str(uuid.uuid4())
        key = f"documents/{doc['doc_type']}/{document_id}/{doc['file_name']}"

        s3.put_object(Bucket=args.bucket, Key=key, Body=doc["text"].encode("utf-8"), ContentType="text/plain")

        dynamodb.put_item(
            Item={
                "document_id": document_id,
                "doc_type": doc["doc_type"],
                "department": doc["department"],
                "upload_ts": datetime.now(timezone.utc).isoformat(),
                "status": "AWAITING_UPLOAD",  # the ingestion worker flips this to PROCESSING once the S3 event arrives
                "s3_uri": f"s3://{args.bucket}/{key}",
            }
        )
        print(f"Uploaded {doc['file_name']} -> document_id={document_id}")

    print(f"\nSeeded {len(SAMPLE_DOCUMENTS)} sample documents into s3://{args.bucket}")


if __name__ == "__main__":
    main()
