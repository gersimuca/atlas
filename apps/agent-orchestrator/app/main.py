import logging

import structlog
from fastapi import FastAPI
from pydantic import BaseModel, Field

from app.agent.bedrock_client import BedrockConverseClient
from app.agent.memory_client import AgentMemoryClient
from app.agent.orchestrator import AgentOrchestrator
from app.agent.tool_executor import build_tool_executor
from app.core.config import get_settings
from app.retrieval.knowledge_base import KnowledgeBaseRetriever

settings = get_settings()

logging.basicConfig(level=settings.log_level)
structlog.configure(processors=[structlog.processors.JSONRenderer()])
logger = structlog.get_logger()

app = FastAPI(
    title="Atlas Agent Orchestrator",
    description="Internal service — runs the Bedrock Converse tool-use loop. Not exposed outside the cluster.",
    version="1.0.0",
)

bedrock_client = BedrockConverseClient(
    region=settings.aws_region,
    model_id=settings.bedrock_model_id,
    guardrail_id=settings.bedrock_guardrail_id,
    guardrail_version=settings.bedrock_guardrail_version,
    use_mock=settings.use_mock_llm,
)
knowledge_base = KnowledgeBaseRetriever(
    region=settings.aws_region,
    knowledge_base_id=settings.bedrock_knowledge_base_id,
    use_mock=settings.use_mock_llm,
)
tool_executor = build_tool_executor(settings)
memory_client = AgentMemoryClient(
    region=settings.aws_region,
    memory_id=settings.agentcore_memory_id,
    enabled=settings.use_agentcore_memory,
)
orchestrator = AgentOrchestrator(
    bedrock_client=bedrock_client,
    tool_executor=tool_executor,
    knowledge_base=knowledge_base,
    memory_client=memory_client,
    max_iterations=settings.max_tool_iterations,
)


class HistoryTurn(BaseModel):
    role: str
    content: str


class InvokeRequest(BaseModel):
    session_id: str
    message: str
    history: list[HistoryTurn] = Field(default_factory=list)


@app.post("/invoke")
def invoke(request: InvokeRequest) -> dict:
    return orchestrator.run(
        session_id=request.session_id,
        user_message=request.message,
        history=[turn.model_dump() for turn in request.history],
    )


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


@app.on_event("startup")
async def on_startup() -> None:
    logger.info(
        "agent_orchestrator.startup",
        environment=settings.environment,
        use_mock_llm=settings.use_mock_llm,
        tool_execution_mode=settings.tool_execution_mode,
        model_id=settings.bedrock_model_id,
    )
