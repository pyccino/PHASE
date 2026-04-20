from pathlib import Path

import pytest


@pytest.fixture
def phase_root() -> Path:
    """Root of the PHASE repository (the directory containing this tests/)."""
    return Path(__file__).parent.parent
