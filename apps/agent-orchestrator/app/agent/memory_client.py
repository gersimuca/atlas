"""Persists conversation turns in Bedrock AgentCore Memory.

Why this exists: agent-orchestrator is a stateless container that can be
scaled to N replicas and restarted at any time by Kubernetes — it can't just
keep conversation history in a Python dict. Rather than bolt on Redis or
sticky sessions, session continuity is delegated to a managed AWS service
built for exactly this. Off by default locally (use_agentcore_memory=False)
since there's no local emulator for it yet; the caller-supplied `history` in
the request body covers local/offline use in the meantime.
"""

import structlog

logger = structlog.get_logger()


class AgentMemoryClient:
    def __init__(self, region: str, memory_id: str, enabled: bool = False):
        self._memory_id = memory_id
        self._enabled = enabled and bool(memory_id)
        self._client = None
        if self._enabled:
            import boto3

            self._client = boto3.client("bedrock-agentcore", region_name=region)

    def load_session(self, session_id: str) -> list[dict]:
        if not self._enabled:
            return []
        try:
            response = self._client.list_events(memoryId=self._memory_id, sessionId=session_id)
            return response.get("events", [])
        except Exception:  # noqa: BLE001 — memory is an enhancement, never fatal to a chat request
            logger.warning("agentcore_memory.load_failed", session_id=session_id, exc_info=True)
            return []

    def record_turn(self, session_id: str, user_message: str, assistant_message: str) -> None:
        if not self._enabled:
            return
        try:
            self._client.create_event(
                memoryId=self._memory_id,
                sessionId=session_id,
                payload=[
                    {"role": "user", "content": user_message},
                    {"role": "assistant", "content": assistant_message},
                ],
            )
        except Exception:  # noqa: BLE001
            logger.warning("agentcore_memory.record_failed", session_id=session_id, exc_info=True)
