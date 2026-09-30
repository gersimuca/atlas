"""Verifies bearer tokens issued by the platform's Cognito user pool.

Feature-flagged via AUTH_ENABLED so local docker-compose runs don't need a
real Cognito user pool just to exercise the API — production deployments
set AUTH_ENABLED=true and point at the real pool.
"""

import time
from dataclasses import dataclass

import httpx
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from jose import jwt
from jose.exceptions import JOSEError

from app.core.config import Settings, get_settings

_bearer_scheme = HTTPBearer(auto_error=False)

_jwks_cache: dict = {"keys": None, "fetched_at": 0.0}
_JWKS_TTL_SECONDS = 3600


@dataclass
class CurrentUser:
    sub: str
    username: str
    raw_claims: dict


def _jwks_url(settings: Settings) -> str:
    return (
        f"https://cognito-idp.{settings.cognito_region}.amazonaws.com/"
        f"{settings.cognito_user_pool_id}/.well-known/jwks.json"
    )


def _get_jwks(settings: Settings) -> dict:
    now = time.time()
    if _jwks_cache["keys"] is None or now - _jwks_cache["fetched_at"] > _JWKS_TTL_SECONDS:
        response = httpx.get(_jwks_url(settings), timeout=5.0)
        response.raise_for_status()
        _jwks_cache["keys"] = response.json()["keys"]
        _jwks_cache["fetched_at"] = now
    return _jwks_cache["keys"]


def _find_key(kid: str, keys: list[dict]) -> dict | None:
    return next((k for k in keys if k["kid"] == kid), None)


async def get_current_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer_scheme),
    settings: Settings = Depends(get_settings),
) -> CurrentUser:
    if not settings.auth_enabled:
        # Local/dev convenience path — never reachable when AUTH_ENABLED=true.
        return CurrentUser(sub="local-dev-user", username="local-dev-user", raw_claims={})

    if credentials is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Missing bearer token")

    try:
        unverified_header = jwt.get_unverified_header(credentials.credentials)
        keys = _get_jwks(settings)
        key = _find_key(unverified_header["kid"], keys)
        if key is None:
            raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Unknown signing key")

        claims = jwt.decode(
            credentials.credentials,
            key,
            algorithms=["RS256"],
            audience=settings.cognito_app_client_id,
            issuer=f"https://cognito-idp.{settings.cognito_region}.amazonaws.com/{settings.cognito_user_pool_id}",
        )
    except JOSEError as exc:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, f"Invalid token: {exc}") from exc

    return CurrentUser(sub=claims["sub"], username=claims.get("username", claims["sub"]), raw_claims=claims)
