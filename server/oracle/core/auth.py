from __future__ import annotations

import hmac
from typing import Annotated

from fastapi import HTTPException, Security, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from oracle.core.config import settings

_bearer_scheme = HTTPBearer(auto_error=False)


async def require_bearer(
    credentials: Annotated[HTTPAuthorizationCredentials | None, Security(_bearer_scheme)],
) -> None:
    if credentials is None or credentials.scheme.lower() != "bearer":
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail="missing or invalid bearer token")
    # Constant-time comparison per PRD §6.4 to prevent timing-attack leaks.
    if not hmac.compare_digest(credentials.credentials, settings.bearer_token):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail="invalid bearer token")
