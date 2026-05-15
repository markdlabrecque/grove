"""CLI argument validation for `python -m oracle.enrichment.reset` (ticket #245).

These tests cover only argparse-level behaviour and do not touch the DB or
the module-level engine used by ``test_enrichment_reset.py``.
"""

from __future__ import annotations

import pytest

from oracle.enrichment.reset import _build_parser


def test_version_below_rejects_zero() -> None:
    parser = _build_parser()
    with pytest.raises(SystemExit):
        parser.parse_args(["--version-below", "0"])


def test_version_below_rejects_negative() -> None:
    parser = _build_parser()
    with pytest.raises(SystemExit):
        parser.parse_args(["--version-below", "-3"])


def test_version_below_accepts_one() -> None:
    parser = _build_parser()
    args = parser.parse_args(["--version-below", "1"])
    assert args.version_below == 1
