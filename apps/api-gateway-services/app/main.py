import logging

import structlog
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.core.config import get_settings
from app.routers import chat, documents

settings = get_settings()

logging.basicConfig(level=settings.log_level)
structlog.configure(processors=[structlog.processors.JSONRenderer()])
logger = structlog.get_logger()

app = FastAPI(
    title="Atlas API Gateway",
    description="Public entry point for the Atlas enterprise document intelligence platform.",
    version="1.0.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # tighten to real origins before any production use
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(documents.router)
app.include_router(chat.router)


@app.get("/health", tags=["ops"])
def health() -> dict:
    """Liveness probe — process is up and can serve requests."""
    return {"status": "ok"}


@app.get("/ready", tags=["ops"])
def ready() -> dict:
    """Readiness probe — distinct from /health so a slow downstream
    dependency takes this pod out of the Service's endpoints without
    the kubelet deciding the container itself is unhealthy and
    restarting it unnecessarily."""
    return {"status": "ready", "environment": settings.environment}


@app.on_event("startup")
async def on_startup() -> None:
    logger.info("api_gateway_service.startup", environment=settings.environment, auth_enabled=settings.auth_enabled)
