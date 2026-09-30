"""Uploads a handful of synthetic sample documents directly to the bronze
bucket via boto3 — unlike the LocalStack init script's direct DynamoDB
inserts, this goes through the real path: S3 upload -> S3 event -> SQS ->
ingestion-worker -> DynamoDB update. Useful both for local demos and for
populating a freshly-deployed real dev environment with something to query.
"""

import argparse
import os
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
            "This agreement is effective as of 2026-01-15 between Atlas Corp "
            "and Northwind Cloud Services.\n"
            "Term: 24 months, with auto-renewal for successive 12-month periods "
            "unless either party gives 90 days' written notice of non-renewal.\n"
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
            "Term: 36 months. No automatic renewal — requires a new agreement "
            "at term end.\n"
            "Payment terms: Net 15, due on the 1st of each month.\n"
        ),
    },
    {
        "doc_type": "invoice",
        "department": "finance",
        "file_name": "invoice-2026-0447.txt",
        "text": (
            "INVOICE #2026-0447\n"
            "Vendor: Northwind Cloud Services\n"
            "Amount: $18,400.00\n"
            "Issued: 2026-06-01. Due: 2026-07-01 (Net 30). "
            "Status: Paid on 2026-06-28.\n"
        ),
    },
    {
        "doc_type": "support_ticket",
        "department": "customer-success",
        "file_name": "ticket-4471.txt",
        "text": (
            "TICKET #4471 — Priority: High\n"
            "Customer reports intermittent 502 errors on the reporting dashboard "
            "during peak hours. Support engineer found the upstream API gateway "
            "was hitting connection pool limits under load.\n"
            "Resolution: increased pool size and added a queue-based backpressure "
            "mechanism.\n"
        ),
    },
    {
        "doc_type": "report",
        "department": "operations",
        "file_name": "q2-2026-uptime-report.txt",
        "text": (
            "Q2 2026 OPERATIONS REPORT\n"
            "Platform uptime: 99.94%. Two incidents, both resolved within SLA. "
            "Support ticket volume up 12% quarter-over-quarter, concentrated in "
            "the reporting dashboard area.\n"
        ),
    },
]


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Seed sample documents into S3 and DynamoDB."
    )

    parser.add_argument(
        "--endpoint-url",
        default=os.getenv("AWS_ENDPOINT_URL", "http://localhost:4566"),
        help="AWS endpoint. Defaults to LocalStack.",
    )

    parser.add_argument(
        "--bucket",
        default="atlas-local-bronze",
    )

    parser.add_argument(
        "--table",
        default="atlas-local-document-metadata",
    )

    parser.add_argument(
        "--region",
        default=os.getenv("AWS_DEFAULT_REGION", "us-east-1"),
    )

    args = parser.parse_args()

    client_kwargs = {
        "region_name": args.region,
    }

    # Configure LocalStack credentials and endpoint.
    if args.endpoint_url:
        client_kwargs.update(
            {
                "endpoint_url": args.endpoint_url,
                "aws_access_key_id": os.getenv(
                    "AWS_ACCESS_KEY_ID", "test"
                ),
                "aws_secret_access_key": os.getenv(
                    "AWS_SECRET_ACCESS_KEY", "test"
                ),
            }
        )

        session_token = os.getenv("AWS_SESSION_TOKEN")
        if session_token:
            client_kwargs["aws_session_token"] = session_token

    print(f"Endpoint: {args.endpoint_url}")
    print(f"Region:   {args.region}")
    print(f"Bucket:   {args.bucket}")
    print(f"Table:    {args.table}")
    print()

    s3 = boto3.client("s3", **client_kwargs)
    dynamodb = boto3.resource(
        "dynamodb",
        **client_kwargs,
    ).Table(args.table)

    for doc in SAMPLE_DOCUMENTS:
        document_id = str(uuid.uuid4())

        key = (
            f"documents/"
            f"{doc['doc_type']}/"
            f"{document_id}/"
            f"{doc['file_name']}"
        )

        # Upload document to S3.
        s3.put_object(
            Bucket=args.bucket,
            Key=key,
            Body=doc["text"].encode("utf-8"),
            ContentType="text/plain",
        )

        # Write metadata to DynamoDB.
        dynamodb.put_item(
            Item={
                "document_id": document_id,
                "doc_type": doc["doc_type"],
                "department": doc["department"],
                "upload_ts": datetime.now(timezone.utc).isoformat(),
                "status": "AWAITING_UPLOAD",
                "s3_uri": f"s3://{args.bucket}/{key}",
            }
        )

        print(
            f"Uploaded {doc['file_name']} "
            f"-> document_id={document_id}"
        )

    print()
    print(
        f"Seeded {len(SAMPLE_DOCUMENTS)} sample documents "
        f"into s3://{args.bucket}"
    )


if __name__ == "__main__":
    main()
