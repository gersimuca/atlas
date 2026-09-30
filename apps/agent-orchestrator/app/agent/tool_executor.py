"""Two ways to actually run query_lakehouse / get_document_metadata once the
model asks for them:

- DirectToolExecutor: this container calls Athena/DynamoDB itself via boto3.
  Simple, works great against LocalStack, fine for a small deployment.
- GatewayToolExecutor: the same two operations are invoked as MCP tools
  through the Bedrock AgentCore Gateway, authenticated with a Cognito
  client-credentials JWT. Centralizes tool governance/auditing in one place
  instead of every service holding its own Athena/DynamoDB IAM permissions.

Selected by TOOL_EXECUTION_MODE so the agent's reasoning loop (orchestrator.py)
never needs to know or care which one is active.
"""

import re
import time
from abc import ABC, abstractmethod

import httpx
import structlog

logger = structlog.get_logger()

FORBIDDEN_SQL_KEYWORDS = re.compile(
    r"\b(insert|update|delete|drop|alter|create|grant|revoke|truncate|merge|copy|unload|vacuum|call|;)\b",
    re.IGNORECASE,
)


class ToolExecutor(ABC):
    @abstractmethod
    def query_lakehouse(self, sql: str) -> dict: ...

    @abstractmethod
    def get_document_metadata(self, document_id: str) -> dict: ...


class DirectToolExecutor(ToolExecutor):
    def __init__(self, region: str, glue_database: str, athena_workgroup: str, athena_output_location: str,
                 metadata_table_name: str, aws_endpoint_url: str | None = None):
        import boto3

        client_kwargs = {"region_name": region}
        if aws_endpoint_url:
            client_kwargs["endpoint_url"] = aws_endpoint_url

        self._athena = boto3.client("athena", **client_kwargs)
        self._dynamodb = boto3.resource("dynamodb", **client_kwargs).Table(metadata_table_name)
        self._glue_database = glue_database
        self._athena_workgroup = athena_workgroup
        self._athena_output_location = athena_output_location

    def query_lakehouse(self, sql: str) -> dict:
        sql = sql.strip()
        if not sql.lower().startswith("select"):
            return {"error": "Only single SELECT statements are permitted."}
        if FORBIDDEN_SQL_KEYWORDS.search(sql):
            return {"error": "Query contains a disallowed keyword or statement separator."}
        if "limit" not in sql.lower():
            sql = f"{sql.rstrip(';')} LIMIT 100"

        execution = self._athena.start_query_execution(
            QueryString=sql,
            QueryExecutionContext={"Database": self._glue_database},
            ResultConfiguration={"OutputLocation": self._athena_output_location},
            WorkGroup=self._athena_workgroup,
        )
        query_execution_id = execution["QueryExecutionId"]

        status = "RUNNING"
        for _ in range(25):
            status = self._athena.get_query_execution(QueryExecutionId=query_execution_id)["QueryExecution"]["Status"]["State"]
            if status in ("SUCCEEDED", "FAILED", "CANCELLED"):
                break
            time.sleep(1)

        if status != "SUCCEEDED":
            return {"error": f"Query did not complete in time (status={status})."}

        results = self._athena.get_query_results(QueryExecutionId=query_execution_id, MaxResults=100)
        rows = results["ResultSet"]["Rows"]
        if not rows:
            return {"columns": [], "rows": []}
        columns = [c.get("VarCharValue", "") for c in rows[0]["Data"]]
        data_rows = [dict(zip(columns, [cell.get("VarCharValue", "") for cell in row["Data"]])) for row in rows[1:]]
        return {"columns": columns, "rows": data_rows}

    def get_document_metadata(self, document_id: str) -> dict:
        item = self._dynamodb.get_item(Key={"document_id": document_id}).get("Item")
        if not item:
            return {"error": f"No document found with id={document_id}."}
        return dict(item)


class GatewayToolExecutor(ToolExecutor):
    """Routes tool calls through the AgentCore Gateway's MCP endpoint,
    authenticating with a short-lived Cognito client-credentials token.

    Implements just enough of MCP (JSON-RPC 2.0 `tools/call`) to invoke a
    named tool — a production system might reach for a full MCP client SDK
    instead of this hand-rolled version.
    """

    def __init__(self, gateway_url: str, token_url: str, client_id: str, client_secret: str):
        self._gateway_url = gateway_url
        self._token_url = token_url
        self._client_id = client_id
        self._client_secret = client_secret
        self._cached_token: str | None = None
        self._token_expires_at: float = 0.0

    def _get_access_token(self) -> str:
        if self._cached_token and time.time() < self._token_expires_at - 30:
            return self._cached_token

        response = httpx.post(
            self._token_url,
            data={"grant_type": "client_credentials", "scope": "atlas-api/tools.invoke"},
            auth=(self._client_id, self._client_secret),
            timeout=10.0,
        )
        response.raise_for_status()
        payload = response.json()
        self._cached_token = payload["access_token"]
        self._token_expires_at = time.time() + payload.get("expires_in", 3600)
        return self._cached_token

    def _call_tool(self, name: str, arguments: dict) -> dict:
        token = self._get_access_token()
        rpc_request = {
            "jsonrpc": "2.0",
            "id": "1",
            "method": "tools/call",
            "params": {"name": name, "arguments": arguments},
        }
        response = httpx.post(
            self._gateway_url,
            json=rpc_request,
            headers={"Authorization": f"Bearer {token}"},
            timeout=30.0,
        )
        response.raise_for_status()
        body = response.json()
        if "error" in body:
            return {"error": body["error"].get("message", "Gateway tool call failed")}
        return body.get("result", {})

    def query_lakehouse(self, sql: str) -> dict:
        return self._call_tool("query_lakehouse", {"sql": sql})

    def get_document_metadata(self, document_id: str) -> dict:
        return self._call_tool("get_document_metadata", {"document_id": document_id})


def build_tool_executor(settings) -> ToolExecutor:
    if settings.tool_execution_mode == "gateway":
        import json

        import boto3

        secrets_client = boto3.client("secretsmanager", region_name=settings.aws_region)
        creds = json.loads(
            secrets_client.get_secret_value(SecretId=settings.agent_m2m_credentials_secret_arn)["SecretString"]
        )
        logger.info("tool_executor.mode", mode="gateway")
        return GatewayToolExecutor(
            gateway_url=creds["gateway_url"],
            token_url=creds["token_url"],
            client_id=creds["client_id"],
            client_secret=creds["client_secret"],
        )

    logger.info("tool_executor.mode", mode="direct")
    return DirectToolExecutor(
        region=settings.aws_region,
        glue_database=settings.glue_gold_database,
        athena_workgroup=settings.athena_workgroup,
        athena_output_location=settings.athena_output_location,
        metadata_table_name=settings.document_metadata_table_name,
        aws_endpoint_url=settings.aws_endpoint_url,
    )
