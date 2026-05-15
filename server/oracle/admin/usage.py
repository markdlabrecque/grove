"""CLI shortcut: python -m oracle.admin.usage

Fetches GET /v1/admin/usage from the local server and prints the JSON
response. Requires the server to be running and BEARER_TOKEN + SERVER_URL
environment variables (or defaults) to be set.

Usage:
    python -m oracle.admin.usage [--url http://localhost:8000]
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys

import httpx


async def _fetch(base_url: str, token: str) -> None:
    async with httpx.AsyncClient(base_url=base_url, timeout=15.0) as client:
        r = await client.get(
            "/v1/admin/usage",
            headers={"Authorization": f"Bearer {token}"},
        )
        r.raise_for_status()
    print(json.dumps(r.json(), indent=2))


def main() -> None:
    parser = argparse.ArgumentParser(description="Print OpenRouter monthly usage summary.")
    parser.add_argument(
        "--url",
        default=os.getenv("ORACLE_SERVER_URL", "http://localhost:8000"),
        help="Base URL of the Oracle server (default: http://localhost:8000)",
    )
    args = parser.parse_args()

    token = os.getenv("BEARER_TOKEN", "")
    if not token:
        print("ERROR: BEARER_TOKEN environment variable is required.", file=sys.stderr)
        sys.exit(1)

    asyncio.run(_fetch(args.url, token))


if __name__ == "__main__":
    main()
