import structlog

from app.agent.bedrock_client import BedrockConverseClient
from app.agent.memory_client import AgentMemoryClient
from app.agent.prompts import SYSTEM_PROMPT
from app.agent.tools import TOOL_SPECS, dispatch_tool_call

logger = structlog.get_logger()


class AgentOrchestrator:
    def __init__(self, bedrock_client: BedrockConverseClient, tool_executor, knowledge_base,
                 memory_client: AgentMemoryClient, max_iterations: int = 5):
        self._bedrock = bedrock_client
        self._tool_executor = tool_executor
        self._knowledge_base = knowledge_base
        self._memory = memory_client
        self._max_iterations = max_iterations

    def run(self, session_id: str, user_message: str, history: list[dict] | None = None) -> dict:
        messages = self._build_initial_messages(session_id, user_message, history or [])

        tool_trace: list[dict] = []
        final_answer = "I wasn't able to reach a final answer within the tool-use budget."
        guardrail_triggered = False

        for _iteration in range(self._max_iterations):
            response = self._bedrock.converse(messages=messages, system_prompt=SYSTEM_PROMPT, tools=TOOL_SPECS)
            stop_reason = response["stopReason"]
            output_message = response["output"]["message"]
            messages.append(output_message)

            if stop_reason == "tool_use":
                tool_results = []
                for block in output_message["content"]:
                    if "toolUse" not in block:
                        continue
                    tool_use = block["toolUse"]
                    logger.info("agent.tool_call", tool=tool_use["name"], input=tool_use["input"])
                    result = dispatch_tool_call(
                        tool_use["name"], tool_use["input"], self._tool_executor, self._knowledge_base
                    )
                    tool_trace.append(
                        {"tool": tool_use["name"], "input": tool_use["input"], "result_preview": str(result)[:300]}
                    )
                    tool_results.append(
                        {
                            "toolResult": {
                                "toolUseId": tool_use["toolUseId"],
                                "content": [{"json": result}] if isinstance(result, (dict, list)) else [{"text": str(result)}],
                            }
                        }
                    )
                messages.append({"role": "user", "content": tool_results})
                continue

            if stop_reason == "guardrail_intervened":
                final_answer = "I can't help with that request."
                guardrail_triggered = True
                break

            if stop_reason in ("end_turn", "stop_sequence", "max_tokens"):
                final_answer = "".join(block.get("text", "") for block in output_message["content"])
                break

            break  # unrecognized stop_reason — fail safe rather than loop forever

        self._memory.record_turn(session_id, user_message, final_answer)

        return {
            "answer": final_answer,
            "session_id": session_id,
            "tool_trace": tool_trace,
            "guardrail_triggered": guardrail_triggered,
        }

    def _build_initial_messages(self, session_id: str, user_message: str, history: list[dict]) -> list[dict]:
        messages: list[dict] = []

        for past_event in self._memory.load_session(session_id):
            for turn in past_event.get("payload", []):
                messages.append({"role": turn["role"], "content": [{"text": turn["content"]}]})

        for turn in history:
            messages.append({"role": turn["role"], "content": [{"text": turn["content"]}]})

        messages.append({"role": "user", "content": [{"text": user_message}]})
        return messages
