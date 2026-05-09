from fastapi import FastAPI

from oracle.api import health
from oracle.core.logging import configure_logging

configure_logging()

app = FastAPI(title="The Oracle", version="0.0.1")
app.include_router(health.router)
