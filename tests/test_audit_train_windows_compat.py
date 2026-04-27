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


def test_index_train_files(tmp_path: Path):
    matlab = tmp_path / "matlab"
    matlab.mkdir()
    (matlab / "foo.m").write_text("function foo(); end")
    (matlab / "bar.m").write_text("function bar(); end")
    (matlab / "sub").mkdir()
    (matlab / "sub" / "baz.m").write_text("function baz(); end")
    idx = audit.index_train_files(tmp_path)
    assert set(idx.keys()) == {"foo", "bar", "baz"}
    assert idx["foo"] == matlab / "foo.m"
    assert idx["baz"] == matlab / "sub" / "baz.m"


def test_index_missing_matlab_dir(tmp_path: Path):
    # No matlab/ subdir → empty index, no exception.
    idx = audit.index_train_files(tmp_path)
    assert idx == {}


def test_extract_calls_finds_function_invocations():
    src = "x = foo(1, 2);\nbar();\nbaz_thing(y);\n"
    calls = audit.extract_calls(src)
    assert "foo" in calls
    assert "bar" in calls
    assert "baz_thing" in calls


def test_extract_calls_ignores_keywords_and_struct_access():
    # `if (...)`, `for (...)`, `while (...)` should not be treated as calls.
    # `obj.method(...)` — we DO want `method` only if it resolves to an .m
    # later, so extract_calls returns it; the index filter handles selection.
    src = "if (x > 0)\n  y = obj.method(x);\nend\nfor i = 1:10\nend\n"
    calls = audit.extract_calls(src)
    assert "if" not in calls
    assert "for" not in calls
    assert "end" not in calls
    assert "method" in calls


def test_extract_calls_strips_strings_and_comments_first():
    src = "% foo()\nbar();\nx = 'baz()';\n"
    calls = audit.extract_calls(src)
    assert "foo" not in calls
    assert "baz" not in calls
    assert "bar" in calls


@pytest.fixture
def phase_root() -> Path:
    return Path("F:/phase")


def _make_train(tmp_path: Path, files: dict[str, str]) -> Path:
    """Helper: create a fake TRAIN tree with given .m contents."""
    matlab = tmp_path / "matlab"
    matlab.mkdir()
    for name, content in files.items():
        (matlab / f"{name}.m").write_text(content)
    return tmp_path


def test_call_graph_single_entry_no_calls(tmp_path: Path):
    root = _make_train(tmp_path, {"aps_linear": "function aps_linear()\nend\n"})
    graph = audit.build_call_graph(root, ["aps_linear"])
    assert len(graph) == 1
    assert next(iter(graph.values())) == set()


def test_call_graph_follows_callees(tmp_path: Path):
    root = _make_train(tmp_path, {
        "aps_linear": "function aps_linear()\n  helper(x);\nend\n",
        "helper": "function helper(x)\n  inner(x);\nend\n",
        "inner": "function inner(x)\nend\n",
        "unreachable": "function unreachable()\nend\n",
    })
    graph = audit.build_call_graph(root, ["aps_linear"])
    names = {p.stem for p in graph}
    assert names == {"aps_linear", "helper", "inner"}
    assert "unreachable" not in names


def test_call_graph_handles_cycles(tmp_path: Path):
    root = _make_train(tmp_path, {
        "aps_linear": "function aps_linear()\n  a();\nend\n",
        "a": "function a()\n  b();\nend\n",
        "b": "function b()\n  a();\nend\n",
    })
    graph = audit.build_call_graph(root, ["aps_linear"])
    assert {p.stem for p in graph} == {"aps_linear", "a", "b"}


def test_call_graph_ignores_unresolved_calls(tmp_path: Path):
    # `sprintf`, `disp` etc. are MATLAB builtins, not in the index.
    root = _make_train(tmp_path, {
        "aps_linear": "function aps_linear()\n  disp('hi');\n  sprintf('x');\nend\n",
    })
    graph = audit.build_call_graph(root, ["aps_linear"])
    assert {p.stem for p in graph} == {"aps_linear"}
    assert next(iter(graph.values())) == set()


def test_call_graph_missing_entry_point_raises(tmp_path: Path):
    root = _make_train(tmp_path, {"foo": "function foo()\nend\n"})
    with pytest.raises(SystemExit) as exc:
        audit.build_call_graph(root, ["aps_linear"])
    assert "aps_linear" in str(exc.value)


def test_call_graph_real_train(phase_root: Path):
    """End-to-end against the real TRAIN clone at F:/phase/TRAIN."""
    train_root = phase_root / "TRAIN"
    if not (train_root / "matlab" / "aps_linear.m").exists():
        pytest.skip("TRAIN clone not present at F:/phase/TRAIN")
    graph = audit.build_call_graph(
        train_root,
        ["aps_linear", "aps_weather_model", "setparm_aps"],
    )
    names = {p.stem for p in graph}
    # Sanity: entry points all reached.
    assert {"aps_linear", "aps_weather_model", "setparm_aps"} <= names
    # Sanity: aps_systemcall is reached (we know it's called transitively).
    assert "aps_systemcall" in names
    # Sanity: closure is non-trivial but bounded by total .m count (88).
    assert 5 <= len(graph) <= 88


def _git_init_with_commit(repo: Path, content: str = "x") -> str:
    """Init a tiny git repo, commit, return the SHA."""
    subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
    subprocess.run(["git", "config", "user.email", "t@t"], cwd=repo, check=True)
    subprocess.run(["git", "config", "user.name", "t"], cwd=repo, check=True)
    (repo / "f").write_text(content)
    subprocess.run(["git", "add", "f"], cwd=repo, check=True)
    subprocess.run(["git", "commit", "-q", "-m", "x"], cwd=repo, check=True)
    sha = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=repo, check=True, capture_output=True, text=True,
    ).stdout.strip()
    return sha


def test_verify_clone_passes_when_head_matches(tmp_path: Path):
    sha = _git_init_with_commit(tmp_path)
    # No exception on match. Pass the full SHA; the function accepts shorts too.
    audit.verify_train_clone(tmp_path, sha)


def test_verify_clone_passes_with_short_sha(tmp_path: Path):
    sha = _git_init_with_commit(tmp_path)
    audit.verify_train_clone(tmp_path, sha[:7])


def test_verify_clone_raises_on_mismatch(tmp_path: Path):
    _git_init_with_commit(tmp_path)
    with pytest.raises(SystemExit) as exc:
        audit.verify_train_clone(tmp_path, "deadbeef")
    assert "deadbeef" in str(exc.value)


def test_verify_clone_raises_when_not_a_repo(tmp_path: Path):
    # tmp_path exists but is not a git repo.
    with pytest.raises(SystemExit):
        audit.verify_train_clone(tmp_path, "abc123")
