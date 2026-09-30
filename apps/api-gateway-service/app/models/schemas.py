from pydantic import BaseModel, Field


class ChatMessage(BaseModel):
    role: str = Field(description="'user' or 'assistant'")
    content: str


class ChatRequest(BaseModel):
    session_id: str = Field(description="Stable ID for this conversation; used to resume AgentCore Memory")
    message: str
    history: list[ChatMessage] = Field(default_factory=list)


class ToolTraceEntry(BaseModel):
    tool: str
    input: dict
    result_preview: str


class ChatResponse(BaseModel):
    answer: str
    session_id: str
    tool_trace: list[ToolTraceEntry] = Field(default_factory=list)
    guardrail_triggered: bool = False


class PresignedUploadRequest(BaseModel):
    file_name: str
    doc_type: str = Field(description="e.g. 'contract', 'invoice', 'support_ticket', 'report'")
    department: str


class PresignedUploadResponse(BaseModel):
    document_id: str
    upload_url: str
    s3_key: str
    expires_in_seconds: int


class DocumentMetadata(BaseModel):
    document_id: str
    doc_type: str | None = None
    department: str | None = None
    upload_ts: str | None = None
    status: str | None = None
    s3_uri: str | None = None
