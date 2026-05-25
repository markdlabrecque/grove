"""Cost-cap pre-flight check for the benchmark runner.

Public API:
    estimate_sweep_cost(models, pricing, n_cases, ...) -> float
    run_cost_preflight(api_key, models, n_cases, cap_usd, ...) -> PreflightResult

Flow:
1. Fetch per-model pricing from OpenRouter /api/v1/models.
2. Fetch current-month spend from /api/v1/auth/key (soft: warns if unavailable).
3. Estimate projected sweep cost from pricing × token estimates × n_cases.
4. If projected + current_spend > cap_usd: raise CostCapError.

The spend endpoint check is soft (warns, does not abort) because OpenRouter
sometimes returns 403 for that endpoint depending on key scope.
"""

from __future__ import annotations

from dataclasses import dataclass

import httpx
import structlog

logger = structlog.get_logger(__name__)

_MODELS_URL = "https://openrouter.ai/api/v1/models"
_KEY_URL = "https://openrouter.ai/api/v1/auth/key"


class CostCapError(Exception):
    """Raised when a sweep's projected cost would exceed the configured cap."""


@dataclass(frozen=True)
class PreflightResult:
    """Summary of the pre-flight cost check."""

    projected_cost_usd: float
    current_spend_usd: float | None
    cap_usd: float
    pricing: dict[str, dict[str, float]]


def estimate_sweep_cost(
    *,
    models: list[str],
    pricing: dict[str, dict[str, float]],
    n_cases: int,
    estimated_input_tokens: int,
    estimated_output_tokens: int,
) -> float:
    """Estimate total sweep cost in USD.

    Args:
        models: List of OpenRouter model IDs to include.
        pricing: Map of model_id → {"prompt": price_per_token, "completion": price_per_token}.
        n_cases: Number of benchmark cases per model.
        estimated_input_tokens: Estimated prompt tokens per case.
        estimated_output_tokens: Estimated completion tokens per case.

    Returns:
        Estimated total cost in USD across all models and cases.

    Raises:
        KeyError: If a model is not present in the pricing dict.
    """
    total = 0.0
    for model in models:
        model_pricing = pricing[model]
        prompt_price = float(model_pricing["prompt"])
        completion_price = float(model_pricing["completion"])
        per_case = (estimated_input_tokens * prompt_price) + (
            estimated_output_tokens * completion_price
        )
        total += per_case * n_cases
    return total


async def _fetch_pricing(api_key: str, models: list[str]) -> dict[str, dict[str, float]]:
    """Fetch pricing for the requested models from OpenRouter /api/v1/models."""
    async with httpx.AsyncClient() as client:
        response = await client.get(
            _MODELS_URL,
            headers={"Authorization": f"Bearer {api_key}"},
            timeout=15.0,
        )
        response.raise_for_status()

    body = response.json()
    all_models = body.get("data", [])
    model_set = set(models)

    pricing: dict[str, dict[str, float]] = {}
    for entry in all_models:
        mid = entry.get("id", "")
        if mid in model_set:
            raw_pricing = entry.get("pricing", {})
            pricing[mid] = {
                "prompt": float(raw_pricing.get("prompt", 0.0)),
                "completion": float(raw_pricing.get("completion", 0.0)),
            }

    return pricing


async def _fetch_current_spend(api_key: str) -> float | None:
    """Fetch current-month spend from /api/v1/auth/key.

    Returns None (soft fall-through with warning) when the endpoint is
    unavailable (e.g. 403 or network error).
    """
    try:
        async with httpx.AsyncClient() as client:
            response = await client.get(
                _KEY_URL,
                headers={"Authorization": f"Bearer {api_key}"},
                timeout=10.0,
            )
            if response.status_code != 200:
                logger.warning(
                    "cost_preflight.spend_endpoint_unavailable",
                    status=response.status_code,
                )
                return None

        body = response.json()
        data = body.get("data", {})
        usage = data.get("usage")
        if usage is not None:
            return float(usage)
        return None
    except httpx.RequestError as exc:
        logger.warning("cost_preflight.spend_endpoint_error", error=str(exc))
        return None


async def run_cost_preflight(
    *,
    api_key: str,
    models: list[str],
    n_cases: int,
    cap_usd: float,
    estimated_input_tokens: int,
    estimated_output_tokens: int,
) -> PreflightResult:
    """Run the cost-cap pre-flight check.

    Fetches pricing and current spend, estimates sweep cost, and raises
    CostCapError if the projected total would exceed cap_usd.

    Args:
        api_key: OpenRouter API key.
        models: List of model IDs to include in the sweep.
        n_cases: Total number of benchmark cases (all workflows combined).
        cap_usd: Monthly spend cap in USD.
        estimated_input_tokens: Estimated input tokens per case.
        estimated_output_tokens: Estimated output tokens per case.

    Returns:
        PreflightResult with projected cost, current spend, and pricing map.

    Raises:
        CostCapError: Projected cost + current spend exceeds cap_usd.
        httpx.HTTPStatusError: If the models endpoint returns a non-2xx status.
        KeyError: If a requested model is not found in the OpenRouter catalog.
    """
    pricing = await _fetch_pricing(api_key, models)
    current_spend = await _fetch_current_spend(api_key)

    projected = estimate_sweep_cost(
        models=models,
        pricing=pricing,
        n_cases=n_cases,
        estimated_input_tokens=estimated_input_tokens,
        estimated_output_tokens=estimated_output_tokens,
    )

    effective_spend = current_spend or 0.0
    if projected + effective_spend > cap_usd:
        raise CostCapError(
            f"Projected sweep cost ${projected:.4f} + current spend "
            f"${effective_spend:.4f} = ${projected + effective_spend:.4f} "
            f"would exceed cap ${cap_usd:.2f}"
        )

    logger.info(
        "cost_preflight.ok",
        projected_cost_usd=projected,
        current_spend_usd=current_spend,
        cap_usd=cap_usd,
    )

    return PreflightResult(
        projected_cost_usd=projected,
        current_spend_usd=current_spend,
        cap_usd=cap_usd,
        pricing=pricing,
    )
