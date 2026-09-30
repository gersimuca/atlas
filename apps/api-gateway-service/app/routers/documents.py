import uuid
from datetime import datetime, timezone

import boto3
from fastapi import APIRouter, Depends, HTTPException

from app.core.config import Settings, get_settings
from app.core.security import CurrentUser, get_current_user
from app.models.schemas import DocumentMetadata, PresignedUploadRequest, PresignedUploadResponse

router = APIRouter(prefix="/documents", tags=["documents"])

_UPLOAD_URL_TTL_SECONDS = 300


def _s3_client(settings: Settings):
    kwargs = {"region_name": settings.aws_region}
    if settings.aws_endpoint_url:
        kwargs["endpoint_url"] = settings.aws_endpoint_url
    return boto3.client("s3", **kwargs)


def _dynamodb_table(settings: Settings):
    kwargs = {"region_name": settings.aws_region}
    if settings.aws_endpoint_url:
        kwargs["endpoint_url"] = settings.aws_endpoint_url
    return boto3.resource("dynamodb", **kwargs).Table(settings.document_metadata_table_name)


@router.post("/upload-url", response_model=PresignedUploadResponse)
def create_upload_url(
    request: PresignedUploadRequest,
    settings: Settings = Depends(get_settings),
    user: CurrentUser = Depends(get_current_user),
) -> PresignedUploadResponse:
    """Returns a presigned S3 PUT URL so the client uploads the file bytes
    directly to S3 — this service never proxies the file contents itself."""
    document_id = str(uuid.uuid4())
    s3_key = f"documents/{request.doc_type}/{document_id}/{request.file_name}"

    client = _s3_client(settings)
    upload_url = client.generate_presigned_url(
        "put_object",
        Params={"Bucket": settings.bronze_bucket_name, "Key": s3_key},
        ExpiresIn=_UPLOAD_URL_TTL_SECONDS,
    )

    table = _dynamodb_table(settings)
    table.put_item(
        Item={
            "document_id": document_id,
            "doc_type": request.doc_type,
            "department": request.department,
            "upload_ts": datetime.now(timezone.utc).isoformat(),
            "status": "AWAITING_UPLOAD",
            "s3_uri": f"s3://{settings.bronze_bucket_name}/{s3_key}",
            "uploaded_by": user.username,
        }
    )

    return PresignedUploadResponse(
        document_id=document_id,
        upload_url=upload_url,
        s3_key=s3_key,
        expires_in_seconds=_UPLOAD_URL_TTL_SECONDS,
    )


@router.get("/{document_id}", response_model=DocumentMetadata)
def get_document(
    document_id: str,
    settings: Settings = Depends(get_settings),
    _user: CurrentUser = Depends(get_current_user),
) -> DocumentMetadata:
    table = _dynamodb_table(settings)
    item = table.get_item(Key={"document_id": document_id}).get("Item")
    if not item:
        raise HTTPException(404, f"No document with id={document_id}")
    return DocumentMetadata(**item)
