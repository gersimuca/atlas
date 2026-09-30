"""Thin wrapper around bedrock-runtime's Converse API.

Converse is used (rather than the older InvokeModel) because it gives a
single, model-family-agnostic interface for multi-turn messages, tool use,
and guardrails — the same client code works whether modelId points at a
Claude cross-region inference profile or something else entirely.
"""

import structlog

logger = structlog.get_logger()


class BedrockConverseClient:
    def __init__(
        self,
        region: str,
        model_id: str,
        guardrail_id: str = "",
        guardrail_version: str = "DRAFT",
        use_mock: bool = True,
    ):
        self._model_id = model_id
        self._guardrail_id = guardrail_id
        self._guardrail_version = guardrail_version
        self._use_mock = use_mock
        self._client = None if use_mock else self._build_client(region)

    @staticmethod
    def _build_client(region: str):
        import boto3
        from botocore.config import Config

        return boto3.client(
            "bedrock-runtime",
            region_name=region,
            config=Config(retries={"max_attempts": 3, "mode": "adaptive"}),
        )

    def converse(
        self,
        messages: list[dict],
        system_prompt: str,
        tools: list[dict] | None = None,
        max_tokens: int = 2048,
        temperature: float = 0.2,
    ) -> dict:
        if self._use_mock:
            return self._mock_converse(messages, tools)

        kwargs: dict = {
            "modelId": self._model_id,
            "messages": messages,
            "system": [{"text": system_prompt}],
            "inferenceConfig": {"maxTokens": max_tokens, "temperature": temperature},
        }
        if tools:
            kwargs["toolConfig"] = {"tools": tools}
        if self._guardrail_id:
            kwargs["guardrailConfig"] = {
                "guardrailIdentifier": self._guardrail_id,
                "guardrailVersion": self._guardrail_version,
            }

        logger.info("bedrock.converse.request", model_id=self._model_id, turn_count=len(messages))
        response = self._client.converse(**kwargs)
        logger.info("bedrock.converse.response", stop_reason=response.get("stopReason"))
        return response

    def _mock_converse(self, messages: list[dict], tools: list[dict] | None) -> dict:
        """Deterministic stand-in for Bedrock so the whole request/response
        shape (including one simulated tool call) works end-to-end without
        any AWS account — useful for a first `docker-compose up` demo, and
        for tests that shouldn't depend on network access or credentials."""
        last_user_text = ""
        for msg in reversed(messages):
            if msg["role"] == "user" and any("text" in b for b in msg["content"]):
                last_user_text = next(b["text"] for b in msg["content"] if "text" in b)
                break

        already_used_tool = any(
            "toolResult" in block
            for msg in messages
            for block in msg.get("content", [])
        )

        if tools and not already_used_tool:
            tool_name = tools[0]["toolSpec"]["name"]
            fake_input = {"query": last_user_text} if "query" in str(tools[0]) else {"sql": "SELECT 1"}
            return {
                "stopReason": "tool_use",
                "output": {
                    "message": {
                        "role": "assistant",
                        "content": [
                            {"text": "Let me check the lakehouse for that."},
                            {"toolUse": {"toolUseId": "mock-tool-call-1", "name": tool_name, "input": fake_input}},
                        ],
                    }
                },
            }

        return {
            "stopReason": "end_turn",
            "output": {
                "message": {
                    "role": "assistant",
                    "content": [
                        {
                            "text": (
                                "[MOCK MODE — no real Bedrock call was made] "
                                f"You asked: \"{last_user_text}\". In a real deployment this would be "
                                "answered by Claude via Amazon Bedrock, grounded in whatever the tools "
                                "above returned. Set USE_MOCK_LLM=false with real AWS credentials and a "
                                "deployed Knowledge Base to see a real answer."
                            )
                        }
                    ],
                }
            },
        }
