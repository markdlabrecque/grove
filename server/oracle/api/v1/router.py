from __future__ import annotations

from fastapi import APIRouter, Depends

from oracle.api import captures, memories, queries
from oracle.core.auth import require_bearer

# All routes registered on this router inherit require_bearer via the
# dependencies list. Individual endpoints don't need to repeat it.
router = APIRouter(
    prefix="/v1",
    dependencies=[Depends(require_bearer)],
)

router.include_router(captures.router)
router.include_router(memories.router)
router.include_router(queries.router)
