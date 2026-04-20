from pathlib import Path


def test_xterm_guard_present(phase_root: Path):
    import zipfile
    with zipfile.ZipFile(phase_root / "PHASE_Preprocessing.mlapp") as z:
        xml = z.read("matlab/document.xml").decode("utf-8")
    assert "if isunix" in xml
    assert "start \"\" /MIN cmd /c" in xml
