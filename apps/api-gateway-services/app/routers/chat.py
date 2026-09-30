import httpx
from fastapi import APIRouter, Depends, HTTPException

from app.core.config import Settings, get_settings
from app.core.security import CurrentUser, get_current_user
from app.models.schemas import ChatRequest, ChatResponse

router = APIRouter(prefix="/chat", tags=["chat"])


@router.post("", response_model=ChatResponse)
async def chat(
    request: ChatRequest,
    settings: Settings = Depends(get_settings),
    _user: CurrentUser = Depends(get_current_user),
) -> ChatResponse:
    """Thin proxy to the internal agent-orchestrator. Kept as a separate
    hop (rather than folding the agent loop into this service) so the
    public-facing surface and the Bedrock-calling surface can scale,
    deploy, and fail independently."""
    async with httpx.AsyncClient(timeout=60.0) as client:
        try:
            response = await client.post(
                f"{settings.agent_orchestrator_url}/invoke",
                json=request.model_dump(),
            )
            response.raise_for_status()
        except httpx.HTTPStatusError as exc:
            raise HTTPException(502, f"agent-orchestrator returned {exc.response.status_code}") from exc
        except httpx.RequestError as exc:
            raise HTTPException(503, f"agent-orchestrator unreachable: {exc}") from exc

    return ChatResponse(**response.json())
