#!/usr/bin/env python3
"""Build ac_0.1.7 using the BIOS-managed MPR2 CD destination mode."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(r"C:\snatcher")
STATIC = ROOT / "extraction" / "patch" / "static"
sys.path.insert(0, str(STATIC))

import build_ac_dynamic_0_1_5 as dynamic  # noqa: E402

dynamic.VERSION = "ac_0.1.7"
dynamic.OUT = ROOT / "build" / "patch" / dynamic.VERSION
dynamic.BIOS_MPR_TRANSFER = True


if __name__ == "__main__":
    dynamic.main()
