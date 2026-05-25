"""Tests for the benchmark cost-cap pre-flight check — ticket #502.

TDD red commit: these tests are written before the implementation exists.

The pre-flight check:
1. Fetches per-model pricing from OpenRouter /api/v1/models
2. Fetches current-month spend from /api/v1/auth/key (soft: warns if unavailable)
3. Estimates sweep cost = sum(input_price * estimated_input_tokens
      + output_price * estimated_output_tokens) * n_cases
4. Aborts with CostCapError if projected cost + current spend would exceed the cap

All HTTP calls are mocked via respx.
"""

from __future__ import annotations

import pytest
import respx
from httpx import Response

from grove.benchmarks.cost_preflight import (
    CostCapError,
    estimate_sweep_cost,
    run_cost_preflight,
)

_MODELS_URL = "https://openrouter.ai/api/v1/models"
_KEY_URL = "https://openrouter.ai/api/v1/auth/key"


def _models_response(*model_ids: str, price_per_million: float = 1.0) -> dict:
    """Minimal /api/v1/models response for the given model IDs."""
    return {
        "data": [
            {
                "id": mid,
                "pricing": {
                    "prompt": str(price_per_million / 1_000_000),
                    "completion": str(price_per_million / 1_000_000),
                },
            }
            for mid in model_ids
        ]
    }


def _key_response(*, usage_usd: float = 0.0, limit_usd: float = 20.0) -> dict:
    return {
        "data": {
            "usage": usage_usd,
            "limit": limit_usd,
        }
    }


# ---------------------------------------------------------------------------
# estimate_sweep_cost — pure calculation
# ---------------------------------------------------------------------------


def test_estimate_sweep_cost_simple():
    """Projected cost = price_per_token * tokens * n_cases."""
    # $1 per 1M tokens, 1000 tokens per case, 10 cases → $0.01
    pricing = {"openai/gpt-4o-mini": {"prompt": 1.0 / 1_000_000, "completion": 1.0 / 1_000_000}}
    cost = estimate_sweep_cost(
        models=["openai/gpt-4o-mini"],
        pricing=pricing,
        n_cases=10,
        estimated_input_tokens=500,
        estimated_output_tokens=500,
    )
    assert abs(cost - 0.01) < 1e-6


def test_estimate_sweep_cost_multiple_models():
    """Cost accumulates across models."""
    pricing = {
        "openai/gpt-4o-mini": {"prompt": 1.0 / 1_000_000, "completion": 1.0 / 1_000_000},
        "openai/gpt-4o": {"prompt": 5.0 / 1_000_000, "completion": 5.0 / 1_000_000},
    }
    cost = estimate_sweep_cost(
        models=["openai/gpt-4o-mini", "openai/gpt-4o"],
        pricing=pricing,
        n_cases=10,
        estimated_input_tokens=500,
        estimated_output_tokens=500,
    )
    # mini: 10 * (500 * 1e-6 + 500 * 1e-6) = 0.01
    # gpt4o: 10 * (500 * 5e-6 + 500 * 5e-6) = 0.05
    assert abs(cost - 0.06) < 1e-6


def test_estimate_sweep_cost_missing_model_raises():
    """Raises KeyError when a model is not in the pricing dict."""
    pricing = {"openai/gpt-4o-mini": {"prompt": 1e-6, "completion": 1e-6}}
    with pytest.raises(KeyError):
        estimate_sweep_cost(
            models=["openai/gpt-4o-mini", "openai/gpt-4o"],
            pricing=pricing,
            n_cases=10,
            estimated_input_tokens=500,
            estimated_output_tokens=500,
        )


# ---------------------------------------------------------------------------
# run_cost_preflight — HTTP integration
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@respx.mock
async def test_preflight_two_models_cost_not_inflated():
    """Projected cost with two models equals cases × sum(per-model costs).

    Regression test for the n_cases over-estimate bug: runner must pass
    len(cases) (per-model count), not len(cases) * len(models).
    """
    # Two models at different prices; 10 cases each.
    # mini  @ $1/M: 10 * (500 + 500) * 1e-6  = $0.01
    # gpt4o @ $5/M: 10 * (500 + 500) * 5e-6  = $0.05
    # Expected total: $0.06
    respx.get(_MODELS_URL).mock(
        return_value=Response(
            200,
            json={
                "data": [
                    {
                        "id": "openai/gpt-4o-mini",
                        "pricing": {
                            "prompt": str(1.0 / 1_000_000),
                            "completion": str(1.0 / 1_000_000),
                        },
                    },
                    {
                        "id": "openai/gpt-4o",
                        "pricing": {
                            "prompt": str(5.0 / 1_000_000),
                            "completion": str(5.0 / 1_000_000),
                        },
                    },
                ]
            },
        )
    )
    respx.get(_KEY_URL).mock(
        return_value=Response(200, json=_key_response(usage_usd=0.0, limit_usd=20.0))
    )

    result = await run_cost_preflight(
        api_key="test-key",
        models=["openai/gpt-4o-mini", "openai/gpt-4o"],
        n_cases=10,
        cap_usd=20.0,
        estimated_input_tokens=500,
        estimated_output_tokens=500,
    )
    # If n_cases were inflated by len(models)=2, projected would be $0.12 instead of $0.06.
    assert abs(result.projected_cost_usd - 0.06) < 1e-6


@pytest.mark.asyncio
@respx.mock
async def test_preflight_passes_under_cap():
    """Pre-flight succeeds when projected cost + current spend is under cap."""
    respx.get(_MODELS_URL).mock(
        return_value=Response(
            200, json=_models_response("openai/gpt-4o-mini", price_per_million=1.0)
        )
    )
    respx.get(_KEY_URL).mock(
        return_value=Response(200, json=_key_response(usage_usd=1.0, limit_usd=20.0))
    )

    # Should not raise
    result = await run_cost_preflight(
        api_key="test-key",
        models=["openai/gpt-4o-mini"],
        n_cases=10,
        cap_usd=20.0,
        estimated_input_tokens=500,
        estimated_output_tokens=500,
    )
    assert result.projected_cost_usd >= 0
    assert result.current_spend_usd == pytest.approx(1.0)


@pytest.mark.asyncio
@respx.mock
async def test_preflight_aborts_over_cap():
    """Pre-flight raises CostCapError when projected sweep would exceed cap."""
    # $10/M tokens, 10 cases, 1000 tokens each → $0.10 projected
    # Current spend = $19.95 → $19.95 + $0.10 > $20 cap
    respx.get(_MODELS_URL).mock(
        return_value=Response(
            200,
            json=_models_response("openai/gpt-4o-mini", price_per_million=10.0),
        )
    )
    respx.get(_KEY_URL).mock(
        return_value=Response(200, json=_key_response(usage_usd=19.95, limit_usd=20.0))
    )

    with pytest.raises(CostCapError):
        await run_cost_preflight(
            api_key="test-key",
            models=["openai/gpt-4o-mini"],
            n_cases=10,
            cap_usd=20.0,
            estimated_input_tokens=500,
            estimated_output_tokens=500,
        )


@pytest.mark.asyncio
@respx.mock
async def test_preflight_key_endpoint_unavailable_warns_not_raises():
    """When /api/v1/auth/key is unavailable, pre-flight warns but does not abort."""
    respx.get(_MODELS_URL).mock(
        return_value=Response(
            200,
            json=_models_response("openai/gpt-4o-mini", price_per_million=1.0),
        )
    )
    # Simulate 403 / unavailable spend endpoint
    respx.get(_KEY_URL).mock(return_value=Response(403, json={"error": "forbidden"}))

    # Should not raise — soft fall-through
    result = await run_cost_preflight(
        api_key="test-key",
        models=["openai/gpt-4o-mini"],
        n_cases=10,
        cap_usd=20.0,
        estimated_input_tokens=500,
        estimated_output_tokens=500,
    )
    # current_spend_usd is None when endpoint is unavailable
    assert result.current_spend_usd is None


@pytest.mark.asyncio
@respx.mock
async def test_preflight_returns_pricing_map():
    """Pre-flight result includes the pricing map for downstream use."""
    respx.get(_MODELS_URL).mock(
        return_value=Response(
            200,
            json=_models_response("openai/gpt-4o-mini", price_per_million=1.0),
        )
    )
    respx.get(_KEY_URL).mock(
        return_value=Response(200, json=_key_response(usage_usd=0.0, limit_usd=20.0))
    )

    result = await run_cost_preflight(
        api_key="test-key",
        models=["openai/gpt-4o-mini"],
        n_cases=5,
        cap_usd=20.0,
        estimated_input_tokens=500,
        estimated_output_tokens=500,
    )
    assert "openai/gpt-4o-mini" in result.pricing
