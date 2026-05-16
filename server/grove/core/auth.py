from __future__ import annotations

import hmac
from typing import Annotated

import structlog
from fastapi import HTTPException, Request, Security, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from grove.core.config import settings
from grove.core.rate_limit import classify_route, consume_for_request

logger = structlog.get_logger()

_bearer_scheme = HTTPBearer(auto_error=False)


async def require_bearer(
    request: Request,
    credentials: Annotated[HTTPAuthorizationCredentials | None, Security(_bearer_scheme)],
) -> None:
    """Validate the bearer token and enforce per-token rate limits.

    Order of operations:
      1. Check that a valid bearer token is present (401 on miss/mismatch).
      2. Classify the request path into a rate-limit bucket (capture/query/default).
      3. Consume one token from the (bearer_token, route_class) bucket.
         If the bucket is empty, return 429 with a Retry-After header.

    Unauthenticated requests (step 1 fails) never reach step 2–3. The rate
    limiter therefore only tracks validated tokens. If a future code path ever
    calls consume_for_request without a real token, it must use the sentinel
    "<anonymous>" so the limiter doesn't crash.
    """
    if credentials is None or credentials.scheme.lower() != "bearer":
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail="missing or invalid bearer token")
    # Constant-time comparison per PRD §6.4 to prevent timing-attack leaks.
    if not hmac.compare_digest(credentials.credentials, settings.bearer_token):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail="invalid bearer token")

    # Rate limit: classify the route then consume one token from the bucket.
    route_class = classify_route(request.url.path)
    allowed, retry_after = consume_for_request(credentials.credentials, route_class)
    if not allowed:
        logger.warning(
            "rate_limit_exceeded",
            route_class=route_class.name,
            retry_after_seconds=retry_after,
        )
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="rate limit exceeded",
            headers={"Retry-After": str(retry_after)},
        )
