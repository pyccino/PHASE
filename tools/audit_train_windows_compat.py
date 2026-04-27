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
