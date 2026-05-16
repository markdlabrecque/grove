from fastapi import FastAPI

from grove.api import health
from grove.api.v1 import router as v1_router
from grove.core.logging import configure_logging

configure_logging()

app = FastAPI(title="Grove", version="0.0.1")
app.include_router(health.router)
app.include_router(v1_router.router)
