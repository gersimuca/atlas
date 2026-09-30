from unittest.mock import MagicMock

from app.agent.bedrock_client import BedrockConverseClient
from app.agent.memory_client import AgentMemoryClient
from app.agent.orchestrator import AgentOrchestrator
from app.agent.tool_executor import DirectToolExecutor
from app.retrieval.knowledge_base import KnowledgeBaseRetriever


def _mock_orchestrator() -> AgentOrchestrator:
    bedrock = BedrockConverseClient(region="us-east-1", model_id="fake-model", use_mock=True)
    kb = KnowledgeBaseRetriever(region="us-east-1", knowledge_base_id="", use_mock=True)
    tool_executor = MagicMock()
    memory = AgentMemoryClient(region="us-east-1", memory_id="", enabled=False)
    return AgentOrchestrator(
        bedrock_client=bedrock, tool_executor=tool_executor, knowledge_base=kb, memory_client=memory
    )


def test_agent_completes_within_tool_iteration_budget() -> None:
    orchestrator = _mock_orchestrator()
    result = orchestrator.run(session_id="s1", user_message="What contracts expire in Q3?")

    assert result["session_id"] == "s1"
    assert result["answer"]  # mock mode still produces a final answer, not an empty string
    assert not result["guardrail_triggered"]


def test_agent_records_a_tool_call_in_the_trace() -> None:
    orchestrator = _mock_orchestrator()
    result = orchestrator.run(session_id="s2", user_message="Summarize our vendor contracts")

    # The mock Bedrock client simulates exactly one tool_use turn before end_turn.
    assert len(result["tool_trace"]) == 1
    assert result["tool_trace"][0]["tool"] in {"search_knowledge_base", "query_lakehouse", "get_document_metadata"}


def test_direct_executor_rejects_non_select_sql() -> None:
    executor = DirectToolExecutor.__new__(DirectToolExecutor)  # skip __init__, no boto3 client needed for this check
    result = executor.query_lakehouse("DROP TABLE documents")
    assert "error" in result


def test_direct_executor_rejects_statement_chaining() -> None:
    executor = DirectToolExecutor.__new__(DirectToolExecutor)
    result = executor.query_lakehouse("SELECT * FROM documents; DROP TABLE documents")
    assert "error" in result


def test_direct_executor_adds_limit_when_missing() -> None:
    """Guards against runaway full-table scans from an open-ended agent query."""
    import app.agent.tool_executor as tool_executor_module

    captured = {}

    class _FakeAthena:
        def start_query_execution(self, **kwargs):
            captured["sql"] = kwargs["QueryString"]
            return {"QueryExecutionId": "fake-id"}

        def get_query_execution(self, **kwargs):
            return {"QueryExecution": {"Status": {"State": "SUCCEEDED"}}}

        def get_query_results(self, **kwargs):
            return {"ResultSet": {"Rows": [{"Data": [{"VarCharValue": "count"}]}, {"Data": [{"VarCharValue": "3"}]}]}}

    executor = tool_executor_module.DirectToolExecutor.__new__(tool_executor_module.DirectToolExecutor)
    executor._athena = _FakeAthena()
    executor._glue_database = "gold"
    executor._athena_workgroup = "agent"
    executor._athena_output_location = "s3://fake/"

    executor.query_lakehouse("SELECT COUNT(*) FROM documents")

    assert "limit" in captured["sql"].lower()
