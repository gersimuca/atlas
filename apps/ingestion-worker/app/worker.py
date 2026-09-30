"""Long-polling consumer: reacts to S3 ObjectCreated events (delivered via
SQS) for newly uploaded documents. For each object: marks it RECEIVED in
DynamoDB, kicks off the bronze Glue crawler so the new file is catalogued,
and (best-effort) asks a SageMaker endpoint to classify it. Runs as a plain
long-running container on EKS rather than Lambda — keeping this on the same
compute/deploy path as the rest of the app was a deliberate choice, not an
oversight; either is a legitimate way to run an SQS consumer.
"""

import json
import logging
import os
import time
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path

import boto3
import structlog

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"))
structlog.configure(processors=[structlog.processors.JSONRenderer()])
logger = structlog.get_logger()

AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
AWS_ENDPOINT_URL = os.environ.get("AWS_ENDPOINT_URL") or None
QUEUE_URL = os.environ["INGESTION_QUEUE_URL"]
METADATA_TABLE_NAME = os.environ["DOCUMENT_METADATA_TABLE_NAME"]
GLUE_CRAWLER_NAME = os.environ.get("GLUE_CRAWLER_NAME", "")
CLASSIFIER_ENDPOINT_NAME = os.environ.get("CLASSIFIER_ENDPOINT_NAME", "")
HEARTBEAT_FILE = Path(os.environ.get("HEARTBEAT_FILE", "/tmp/worker-heartbeat"))
POLL_WAIT_SECONDS = 10

_client_kwargs = {"region_name": AWS_REGION}
if AWS_ENDPOINT_URL:
    _client_kwargs["endpoint_url"] = AWS_ENDPOINT_URL

sqs = boto3.client("sqs", **_client_kwargs)
dynamodb = boto3.resource("dynamodb", **_client_kwargs).Table(METADATA_TABLE_NAME)
glue = boto3.client("glue", **_client_kwargs)
sagemaker_runtime = boto3.client("sagemaker-runtime", **_client_kwargs)


def _touch_heartbeat() -> None:
    HEARTBEAT_FILE.write_text(str(time.time()))


def _extract_s3_events(sqs_body: dict) -> list[dict]:
    """S3 -> SQS notifications wrap one or more s3:ObjectCreated records."""
    return sqs_body.get("Records", [])


def _classify_document(bucket: str, key: str) -> str | None:
    if not CLASSIFIER_ENDPOINT_NAME:
        return None
    try:
        response = sagemaker_runtime.invoke_endpoint(
            EndpointName=CLASSIFIER_ENDPOINT_NAME,
            ContentType="application/json",
            Body=json.dumps({"s3_uri": f"s3://{bucket}/{key}"}),
        )
        return json.loads(response["Body"].read())["predicted_label"]
    except Exception:  # noqa: BLE001 — classification is an enhancement, ingestion must still succeed without it
        logger.warning("classifier.invoke_failed", bucket=bucket, key=key, exc_info=True)
        return None


def _handle_s3_record(record: dict) -> None:
    bucket = record["s3"]["bucket"]["name"]
    key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])
    document_id = key.split("/")[-2] if key.count("/") >= 2 else key  # documents/<type>/<document_id>/<file>

    logger.info("ingestion.object_received", bucket=bucket, key=key, document_id=document_id)

    predicted_label = _classify_document(bucket, key)

    update_expression = "SET #status = :status, processed_ts = :ts"
    expression_names = {"#status": "status"}
    expression_values = {":status": "PROCESSING", ":ts": datetime.now(timezone.utc).isoformat()}
    if predicted_label:
        update_expression += ", predicted_doc_type = :label"
        expression_values[":label"] = predicted_label

    dynamodb.update_item(
        Key={"document_id": document_id},
        UpdateExpression=update_expression,
        ExpressionAttributeNames=expression_names,
        ExpressionAttributeValues=expression_values,
    )

    if GLUE_CRAWLER_NAME:
        try:
            glue.start_crawler(Name=GLUE_CRAWLER_NAME)
        except glue.exceptions.CrawlerRunningException:
            logger.info("glue.crawler_already_running", crawler=GLUE_CRAWLER_NAME)


def run_forever() -> None:
    logger.info("ingestion_worker.started", queue_url=QUEUE_URL)
    while True:
        _touch_heartbeat()
        response = sqs.receive_message(
            QueueUrl=QUEUE_URL,
            MaxNumberOfMessages=5,
            WaitTimeSeconds=POLL_WAIT_SECONDS,
        )
        messages = response.get("Messages", [])

        for message in messages:
            try:
                body = json.loads(message["Body"])
                for record in _extract_s3_events(body):
                    _handle_s3_record(record)
                sqs.delete_message(QueueUrl=QUEUE_URL, ReceiptHandle=message["ReceiptHandle"])
            except Exception:  # noqa: BLE001 — leave the message for redelivery/DLQ rather than crash the worker
                logger.error("ingestion.message_processing_failed", exc_info=True)


if __name__ == "__main__":
    run_forever()
