#!/usr/bin/env bash
set -euo pipefail

echo "Bootstrapping LocalStack resources for Atlas local dev..."

awslocal s3 mb s3://atlas-local-bronze
awslocal s3 mb s3://atlas-local-athena-results

awslocal dynamodb create-table \
  --table-name atlas-local-document-metadata \
  --attribute-definitions AttributeName=document_id,AttributeType=S \
  --key-schema AttributeName=document_id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST

QUEUE_URL=$(awslocal sqs create-queue --queue-name atlas-local-ingestion-events --query 'QueueUrl' --output text)
echo "Created queue: ${QUEUE_URL}"

# S3 -> SQS event notifications work in LocalStack Community too, so
# uploads through api-gateway-service's presigned URL really do wake the
# ingestion worker up, the same as they would against real AWS.
QUEUE_ARN=$(awslocal sqs get-queue-attributes --queue-url "${QUEUE_URL}" --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)
awslocal s3api put-bucket-notification-configuration \
  --bucket atlas-local-bronze \
  --notification-configuration "{\"QueueConfigurations\": [{\"QueueArn\": \"${QUEUE_ARN}\", \"Events\": [\"s3:ObjectCreated:*\"], \"Filter\": {\"Key\": {\"FilterRules\": [{\"Name\": \"prefix\", \"Value\": \"documents/\"}]}}}]}"

echo "Seeding sample document metadata..."
awslocal dynamodb put-item --table-name atlas-local-document-metadata --item '{
  "document_id": {"S": "seed-contract-001"},
  "doc_type": {"S": "contract"},
  "department": {"S": "procurement"},
  "upload_ts": {"S": "2026-05-14T09:00:00+00:00"},
  "status": {"S": "PROCESSED"},
  "s3_uri": {"S": "s3://atlas-local-bronze/documents/contract/seed-contract-001/vendor-agreement.txt"}
}'

awslocal dynamodb put-item --table-name atlas-local-document-metadata --item '{
  "document_id": {"S": "seed-ticket-001"},
  "doc_type": {"S": "support_ticket"},
  "department": {"S": "customer-success"},
  "upload_ts": {"S": "2026-06-02T14:30:00+00:00"},
  "status": {"S": "PROCESSED"},
  "s3_uri": {"S": "s3://atlas-local-bronze/documents/support_ticket/seed-ticket-001/ticket-4471.txt"}
}'

echo "Done. Try:"
echo "  curl http://localhost:8001/health"
echo "  curl -X POST http://localhost:8000/chat -H 'Content-Type: application/json' \\"
echo "       -d '{\"session_id\": \"demo-1\", \"message\": \"What contracts do we have on file?\"}'"
