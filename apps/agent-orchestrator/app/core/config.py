from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="", extra="ignore")

    environment: str = "local"
    aws_region: str = "us-east-1"
    log_level: str = "INFO"

    # --- Bedrock ---
    bedrock_model_id: str = "us.anthropic.claude-sonnet-4-6"
    bedrock_guardrail_id: str = ""
    bedrock_guardrail_version: str = "DRAFT"
    bedrock_knowledge_base_id: str = ""

    # --- Mock mode: skip real Bedrock calls entirely (no AWS account
    # needed) so `docker-compose up` produces a working demo out of the
    # box. Real Bedrock is still fully wired up in bedrock_client.py —
    # this flag just short-circuits it for offline use. ---
    use_mock_llm: bool = True

    # --- Tool execution: "direct" calls Athena/DynamoDB straight from
    # this container (works against LocalStack, simplest for local dev
    # and small deployments); "gateway" routes the same two tools
    # through the AgentCore Gateway for centralized MCP governance
    # (what you'd flip on in a real enterprise deployment). ---
    tool_execution_mode: str = "direct"

    glue_gold_database: str = "atlas_dev_gold"
    athena_workgroup: str = "atlas-dev-agent"
    athena_output_location: str = "s3://atlas-dev-athena-results/agent/"
    document_metadata_table_name: str = "atlas-dev-document-metadata"

    # --- Gateway mode only ---
    agentcore_gateway_url: str = ""
    agent_m2m_credentials_secret_arn: str = ""

    # --- AgentCore Memory ---
    agentcore_memory_id: str = ""
    use_agentcore_memory: bool = False  # off locally (no LocalStack support for AgentCore yet)

    # --- LocalStack support ---
    aws_endpoint_url: str | None = None

    max_tool_iterations: int = 5


@lru_cache
def get_settings() -> Settings:
    return Settings()
