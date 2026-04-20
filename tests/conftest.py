from pathlib import Path

import pytest


@pytest.fixture
def phase_root() -> Path:
    return Path(__file__).parent.parent
