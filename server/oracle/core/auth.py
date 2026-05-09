import secrets
from typing import Annotated

from fastapi import Depends, Header, HTTPException, status

from oracle.core.config import settings


async def require_bearer(
    authorization: Annotated[str | None, Header()] = None,
) -> None:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "missing bearer token")
    token = authorization.removeprefix("Bearer ").strip()
    if not secrets.compare_digest(token, settings.bearer_token):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "invalid bearer token")


BearerAuth = Annotated[None, Depends(require_bearer)]
