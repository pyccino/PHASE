"""Tests for the Roberto v4 fix bundle (rm_rf_glob lock + cd-restore + fclose).

Root cause: `StaMPS/matlab/ps_load_initial_gamma.m` opened `pscands.1.ph`
with fopen() but never closed it; the leaked handle locked the file on
Windows so the next mt_prep_snap run failed deleting PATCH_*. Fix lives
in three places, this module verifies each:

  - _shell.rm_rf_glob now raises an actionable PermissionError on Windows
  - PHASE_StaMPS.mlapp checks mt_prep_snap exit code AND restores cwd
  - ps_load_initial_gamma.m calls fclose on the pscands.1.ph fid
"""
from __future__ import annotations

import os
import re
import sys
import zipfile
from pathlib import Path

import pytest


def _read_mlapp_xml(path: Path) -> str:
    with zipfile.ZipFile(path) as z:
        return z.read("matlab/document.xml").decode("utf-8")


# ---------------------------------------------------------------------------
# Fix #1: ps_load_initial_gamma.m must close the pscands.1.ph fid.
# ---------------------------------------------------------------------------

def test_ps_load_initial_gamma_closes_phname(phase_root: Path):
    """The fopen(phname, ...) for pscands.1.ph MUST be matched by a
    subsequent fclose(fid) before the variable is overwritten by another
    fopen. Without this, the file handle leaks until MATLAB exits — and on
    Windows that lock blocks the next mt_prep_snap rm_rf_glob."""
    src = phase_root / "StaMPS/matlab/ps_load_initial_gamma.m"
    if not src.exists():
        pytest.skip("StaMPS sub-repo not present in this checkout")
    text = src.read_text(encoding="utf-8", errors="replace")
    # Find the fopen for phname (pscands.1.ph)
    m = re.search(r"fid\s*=\s*fopen\(phname[^\n]*", text)
    assert m is not None, "expected fopen(phname,...) in ps_load_initial_gamma.m"
    after = text[m.end():]
    # The next fopen would overwrite fid; we want fclose(fid) to come first.
    next_fopen = re.search(r"\bfopen\b", after)
    next_fclose = re.search(r"\bfclose\(fid\)", after)
    assert next_fclose is not None, "no fclose(fid) after fopen(phname,...)"
    if next_fopen is not None:
        assert next_fclose.start() < next_fopen.start(), (
            "fclose(fid) for pscands.1.ph must come BEFORE the next fopen "
            "overwrites fid (otherwise the handle leaks)"
        )


# ---------------------------------------------------------------------------
# Fix #2: PHASE_StaMPS.mlapp catches mt_prep_snap failures + restores cwd.
# ---------------------------------------------------------------------------

def test_mlapp_checks_mt_prep_snap_exit_code(phase_root: Path):
    """Both Windows branches that invoke mt_prep_snap.bat must capture its
    exit status and raise an error if non-zero, instead of silently letting
    stamps(...) run on stale data."""
    xml = _read_mlapp_xml(phase_root / "PHASE_Preprocessing/PHASE_StaMPS.mlapp")
    # The new code uses `mt_prep_snap_status = system(...)` + `error(...)`
    assert "mt_prep_snap_status = system(" in xml
    assert "PHASE_StaMPS:mtPrepSnapFailed" in xml
    # Both invocation sites (train_flag==0 and train_flag~=0) should be wrapped
    assert xml.count("mt_prep_snap_status = system(") == 2
    # And the bare `system([which('mt_prep_snap.bat')...])` should be gone.
    bare = re.findall(
        r"^\s*system\(\[which\('mt_prep_snap\.bat'\)",
        xml, flags=re.MULTILINE,
    )
    assert bare == [], f"bare unchecked system() still present: {bare}"


def test_mlapp_catch_restores_working_directory(phase_root: Path):
    """The outer catch in StartButtonPushed must restore cd(cd_fullpath)
    so the next Start press doesn't inherit a stale pwd like .../PATCH_1
    (left behind by stamps.m on errors mid-loop)."""
    xml = _read_mlapp_xml(phase_root / "PHASE_Preprocessing/PHASE_StaMPS.mlapp")
    # Look for the catch block we patched: it captures the exception as ME,
    # checks cd_fullpath, and cd's back to it.
    assert "catch ME" in xml
    assert "exist('cd_fullpath', 'var')" in xml
    assert "cd(cd_fullpath)" in xml
    # And the error message should include ME.message so the user sees the
    # real cause instead of a generic "check the log file" line.
    assert "ME.message" in xml


# ---------------------------------------------------------------------------
# Fix #3: rm_rf_glob raises actionable PermissionError on Windows.
# ---------------------------------------------------------------------------

@pytest.mark.windows_only
def test_rm_rf_glob_raises_actionable_message_on_windows_lock(tmp_path: Path,
                                                               phase_root: Path):
    """When a file under the glob target is locked by another process,
    rm_rf_glob should raise PermissionError with a message that names
    MATLAB and tells the user what to do — not a raw shutil traceback."""
    stamps_py = phase_root / "StaMPS/python"
    if not stamps_py.exists():
        pytest.skip("StaMPS sub-repo not present in this checkout")
    sys.path.insert(0, str(stamps_py))
    try:
        from stamps._shell import rm_rf_glob  # type: ignore
    finally:
        sys.path.pop(0)

    # Build a directory deep enough to pass the depth>=3 safety check.
    workdir = tmp_path / "fake_stamps_root" / "ASC_test" / "run"
    patch = workdir / "PATCH_1"
    patch.mkdir(parents=True)
    locked = patch / "pscands.1.ph"
    locked.write_bytes(b"x" * 16)

    # Open with exclusive sharing so even unlink() is refused (mimics MATLAB
    # holding the handle from a leaked fopen). On Windows the default
    # `open(... 'rb')` already excludes FILE_SHARE_DELETE, so unlink fails.
    fh = open(locked, "rb")
    try:
        with pytest.raises(PermissionError) as exc:
            rm_rf_glob(workdir / "PATCH_*", retries=1, backoff_s=0)
        msg = str(exc.value).lower()
        assert "matlab" in msg, f"message should mention MATLAB; got: {exc.value}"
        assert "close" in msg or "another process" in msg, (
            f"message should tell the user what to do; got: {exc.value}"
        )
    finally:
        fh.close()


def test_rm_rf_glob_actionable_branch_is_windows_gated(phase_root: Path):
    """The friendly Windows-only re-raise branch must check os.name == 'nt'
    so POSIX behavior (re-raise the original PermissionError unchanged) is
    preserved."""
    src = phase_root / "StaMPS/python/stamps/_shell.py"
    if not src.exists():
        pytest.skip("StaMPS sub-repo not present in this checkout")
    text = src.read_text(encoding="utf-8")
    # The branch we added is gated on os.name == "nt"; outside that gate the
    # original `raise` must still exist.
    assert 'os.name == "nt"' in text
    # And an actionable hint about MATLAB must be present in the message.
    # (The full sentence is split across multiple f-strings in the source,
    # so we look for stable, unbroken fragments.)
    assert "MATLAB session" in text and "Close all MATLAB" in text
