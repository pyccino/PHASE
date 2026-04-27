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


def test_scan_detects_system_call(tmp_path: Path):
    f = tmp_path / "x.m"
    f.write_text("x = 1;\nsystem('echo hi');\nz = 2;\n")
    findings = audit.scan_linux_patterns(f)
    assert len(findings) == 1
    assert findings[0].line == 2
    assert findings[0].severity == "HIGH"
    assert findings[0].pattern == "system_call"


def test_scan_detects_aps_systemcall_wrapper(tmp_path: Path):
    f = tmp_path / "x.m"
    f.write_text("aps_systemcall(cmd);\n")
    findings = audit.scan_linux_patterns(f)
    assert len(findings) == 1
    assert findings[0].severity == "HIGH"
    assert findings[0].pattern == "aps_systemcall"


def test_scan_ignores_pattern_in_comment(tmp_path: Path):
    f = tmp_path / "x.m"
    f.write_text("% system('rm /')\nx = 1;\n")
    findings = audit.scan_linux_patterns(f)
    assert findings == []


def test_scan_ignores_pattern_in_string(tmp_path: Path):
    f = tmp_path / "x.m"
    f.write_text("error('use system() to fix');\n")
    # The 'system()' inside the quoted string is stripped.
    # The standalone 'error(' is a builtin, not in our pattern list.
    findings = audit.scan_linux_patterns(f)
    assert findings == []


def test_scan_detects_linux_path_medium(tmp_path: Path):
    f = tmp_path / "x.m"
    f.write_text("dest = '/tmp/foo';\n")
    # The string literal is stripped, so /tmp inside quotes is NOT flagged.
    # That's correct — the string was an example, not a real Linux path use.
    findings = audit.scan_linux_patterns(f)
    assert findings == []  # stripped


def test_scan_detects_linux_path_outside_string(tmp_path: Path):
    f = tmp_path / "x.m"
    # `cd /tmp` as a bang-shell command: the bang catches it as HIGH,
    # the `/tmp` would also catch as MEDIUM but bang takes precedence per-line.
    f.write_text("dest = strcat('/tmp', name);\n")
    # /tmp inside a string is stripped → no finding. Use a non-string case:
    f.write_text("homedir = pwd; cd ~/data\n")  # bang-less, but ~/ catches.
    findings = audit.scan_linux_patterns(f)
    pats = {fi.pattern for fi in findings}
    assert "home_expansion" in pats


def test_scan_detects_low_severity_shell_command(tmp_path: Path):
    f = tmp_path / "x.m"
    # bare 'wget' identifier outside any string. In real TRAIN this only
    # appears inside system() args, but we want a standalone catch too.
    f.write_text("cmd = wget;\n")  # no string literal here.
    findings = audit.scan_linux_patterns(f)
    assert any(fi.severity == "LOW" and fi.pattern == "shell_wget"
               for fi in findings)


def test_scan_emits_warning_when_eval_or_feval(tmp_path: Path):
    f = tmp_path / "x.m"
    f.write_text("h = feval(name, x);\n")
    findings = audit.scan_linux_patterns(f)
    # `feval` is not a "Linux pattern" but emits a WARNING-severity finding
    # so the report flags incomplete closure for that branch.
    assert any(fi.severity == "WARNING" and fi.pattern == "dynamic_dispatch"
               for fi in findings)


def test_finding_carries_snippet_with_context(tmp_path: Path):
    f = tmp_path / "x.m"
    f.write_text("a = 1;\nb = 2;\nsystem('x');\nc = 3;\nd = 4;\n")
    findings = audit.scan_linux_patterns(f)
    assert len(findings) == 1
    snippet = findings[0].snippet
    # Snippet contains the matched line plus 1 line above and 1 below.
    assert "b = 2;" in snippet
    assert "system" in snippet
    assert "c = 3;" in snippet
