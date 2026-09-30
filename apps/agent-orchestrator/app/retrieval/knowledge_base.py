"""Wraps bedrock-agent-runtime's Retrieve API — the RAG half of the agent.
query_lakehouse (Athena) handles the structured/numeric half; this handles
semantic search over document text indexed into the knowledge base.
"""

import structlog

logger = structlog.get_logger()


class KnowledgeBaseRetriever:
    def __init__(self, region: str, knowledge_base_id: str, use_mock: bool = True):
        self._knowledge_base_id = knowledge_base_id
        self._use_mock = use_mock or not knowledge_base_id
        self._client = None if self._use_mock else self._build_client(region)

    @staticmethod
    def _build_client(region: str):
        import boto3

        return boto3.client("bedrock-agent-runtime", region_name=region)

    def search(self, query: str, top_k: int = 5) -> dict:
        if self._use_mock:
            return {
                "results": [
                    {
                        "content": (
                            "[MOCK MODE] No Knowledge Base is configured. In a real deployment this "
                            f"would return the top {top_k} semantically relevant passages for: '{query}'."
                        ),
                        "source_uri": "s3://atlas-dev-gold/documents/mock-example.txt",
                        "score": 0.0,
                    }
                ]
            }

        logger.info("knowledge_base.retrieve", query=query, top_k=top_k)
        response = self._client.retrieve(
            knowledgeBaseId=self._knowledge_base_id,
            retrievalQuery={"text": query},
            retrievalConfiguration={"vectorSearchConfiguration": {"numberOfResults": top_k}},
        )

        results = []
        for item in response.get("retrievalResults", []):
            results.append(
                {
                    "content": item["content"]["text"][:1000],
                    "source_uri": item.get("location", {}).get("s3Location", {}).get("uri"),
                    "score": item.get("score"),
                }
            )
        return {"results": results}
