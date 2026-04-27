"""Tests for tools/audit_train_windows_compat.py."""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

# Make the tool importable. tools/ is not a package.
TOOLS_DIR = Path(__file__).resolve().parent.parent / "tools"
sys.path.insert(0, str(TOOLS_DIR))

import audit_train_windows_compat as audit


def test_strip_removes_line_comment():
    src = "x = 1; % system('rm -rf /')\nfoo();"
    out = audit.strip_matlab_noise(src)
    # Line offsets preserved (newline kept, comment chars become spaces).
    assert "system" not in out
    assert "rm -rf" not in out
    assert out.count("\n") == src.count("\n")


def test_strip_removes_single_quoted_string():
    src = "msg = 'system(rm /tmp/x)'; bar();"
    out = audit.strip_matlab_noise(src)
    # The literal content of the string must not survive.
    assert "system(rm" not in out
    assert "bar" in out  # code outside the string is untouched.


def test_strip_preserves_line_columns():
    src = "abc % comment\nxyz"
    out = audit.strip_matlab_noise(src)
    # Length per line preserved so line numbers and column offsets match.
    assert len(out.splitlines()[0]) == len("abc % comment")
    assert out.splitlines()[1] == "xyz"


def test_strip_handles_escaped_quote_in_string():
    # MATLAB escapes a single quote by doubling it: 'it''s'
    src = "s = 'it''s a test'; q();"
    out = audit.strip_matlab_noise(src)
    assert "test" not in out
    assert "q()" in out


def test_strip_keeps_transpose_operator():
    # `A'` is the transpose operator, not a string. Heuristic: a single
    # quote following an alphanumeric/closing-bracket character is transpose.
    src = "y = A' * b;"
    out = audit.strip_matlab_noise(src)
    assert "A'" in out
    assert "b" in out
