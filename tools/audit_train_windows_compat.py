"""Static audit of TRAIN's Windows compatibility, scoped to the closure
of TRAIN functions actually invoked by PHASE.

Entry points (verified by extracting PHASE_StaMPS.mlapp):
- aps_linear
- aps_weather_model
- setparm_aps

Run: python tools/audit_train_windows_compat.py [--train-path F:/phase/TRAIN]
"""
from __future__ import annotations

import sys


def strip_matlab_noise(src: str) -> str:
    """Replace MATLAB line comments and single-quoted string literals with
    spaces, preserving line/column offsets.

    Distinguishes the transpose operator (`A'`) from a string opening quote:
    a `'` immediately following an identifier, digit, `)`, `]`, `}`, or `.`
    is treated as transpose. Otherwise it opens a string. MATLAB escapes a
    single quote inside a string by doubling it (`''`).
    """
    out = []
    i = 0
    n = len(src)
    transpose_prev = False  # True if previous non-space char allows transpose.
    while i < n:
        ch = src[i]
        if ch == "%":
            # Line comment to end-of-line.
            while i < n and src[i] != "\n":
                out.append(" ")
                i += 1
            transpose_prev = False
            continue
        if ch == "'" and not transpose_prev:
            # String literal until next un-doubled quote.
            out.append(" ")
            i += 1
            while i < n:
                if src[i] == "'":
                    # Check for doubled quote (escaped).
                    if i + 1 < n and src[i + 1] == "'":
                        out.append("  ")
                        i += 2
                        continue
                    out.append(" ")
                    i += 1
                    break
                if src[i] == "\n":
                    out.append("\n")
                else:
                    out.append(" ")
                i += 1
            transpose_prev = False
            continue
        out.append(ch)
        if ch.isalnum() or ch in ")]}._":
            transpose_prev = True
        elif ch.isspace():
            pass  # whitespace doesn't change transpose context.
        else:
            transpose_prev = False
        i += 1
    return "".join(out)
