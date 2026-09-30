TOOL_SPECS = [
    {
        "toolSpec": {
            "name": "search_knowledge_base",
            "description": (
                "Search the enterprise knowledge base (contracts, invoices, tickets, reports) for "
                "relevant passages using semantic search. Use for open-ended or conceptual questions."
            ),
            "inputSchema": {
                "json": {
                    "type": "object",
                    "properties": {"query": {"type": "string", "description": "Natural language search query"}},
                    "required": ["query"],
                }
            },
        }
    },
    {
        "toolSpec": {
            "name": "query_lakehouse",
            "description": (
                "Run a read-only SQL SELECT query against the curated (gold) lakehouse tables via Athena. "
                "Use for aggregate, numeric, or structured questions (counts, sums, trends)."
            ),
            "inputSchema": {
                "json": {
                    "type": "object",
                    "properties": {"sql": {"type": "string", "description": "A single SELECT statement"}},
                    "required": ["sql"],
                }
            },
        }
    },
    {
        "toolSpec": {
            "name": "get_document_metadata",
            "description": "Fetch metadata for a specific document by its document_id.",
            "inputSchema": {
                "json": {
                    "type": "object",
                    "properties": {"document_id": {"type": "string"}},
                    "required": ["document_id"],
                }
            },
        }
    },
]


def dispatch_tool_call(name: str, tool_input: dict, tool_executor, knowledge_base) -> dict:
    if name == "search_knowledge_base":
        return knowledge_base.search(tool_input["query"])
    if name == "query_lakehouse":
        return tool_executor.query_lakehouse(tool_input["sql"])
    if name == "get_document_metadata":
        return tool_executor.get_document_metadata(tool_input["document_id"])
    return {"error": f"Unknown tool: {name}"}
