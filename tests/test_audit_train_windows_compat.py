"""Tests for tools/audit_train_windows_compat.py."""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

# Make the tool importable. tools/ is not a package.
TOOLS_DIR = Path(__file__).resolve().parent.parent / "tools"
sys.path.insert(0, str(TOOLS_DIR))
