from unittest.mock import AsyncMock, patch

import pytest
from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_health() -> None:
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_ready() -> None:
    response = client.get("/ready")
    assert response.status_code == 200
    assert response.json()["status"] == "ready"


def test_chat_proxies_to_agent_orchestrator() -> None:
    fake_agent_response = {
        "answer": "There are 3 contracts expiring in Q3 with auto-renewal clauses.",
        "session_id": "session-123",
        "tool_trace": [],
        "guardrail_triggered": False,
    }

    with patch("app.routers.chat.httpx.AsyncClient") as mock_client_cls:
        mock_client = AsyncMock()
        mock_response = AsyncMock()
        mock_response.raise_for_status = lambda: None
        mock_response.json = lambda: fake_agent_response
        mock_client.post.return_value = mock_response
        mock_client_cls.return_value.__aenter__.return_value = mock_client

        response = client.post(
            "/chat",
            json={"session_id": "session-123", "message": "Which contracts expire in Q3?", "history": []},
        )

    assert response.status_code == 200
    assert response.json()["answer"] == fake_agent_response["answer"]


@pytest.mark.parametrize("path", ["/documents/does-not-exist"])
def test_get_unknown_document_returns_404(path: str) -> None:
    with patch("app.routers.documents._dynamodb_table") as mock_table_factory:
        mock_table = mock_table_factory.return_value
        mock_table.get_item.return_value = {}
        response = client.get(path)
    assert response.status_code == 404
