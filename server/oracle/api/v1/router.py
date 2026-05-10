from __future__ import annotations

from fastapi import APIRouter, Depends

from oracle.core.auth import require_bearer

# All routes registered on this router inherit require_bearer via the
# dependencies list. Individual endpoints don't need to repeat it.
router = APIRouter(
    prefix="/v1",
    dependencies=[Depends(require_bearer)],
)


# Placeholder endpoint — exists only so tests have an authenticated route to
# call. Delete when POST /v1/captures lands in the next ticket.
@router.get("/ping")
async def ping() -> dict[str, str]:
    return {"status": "pong"}
