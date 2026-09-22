#!/usr/bin/env python3
"""Build ac_0.1.8: helper in MPR5, AC transfer via game's safe MPR4 mode."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(r"C:\snatcher")
STATIC = ROOT / "extraction" / "patch" / "static"
sys.path.insert(0, str(STATIC))

import build_ac_dynamic_0_1_5 as dynamic  # noqa: E402

dynamic.VERSION = "ac_0.1.8"
dynamic.OUT = ROOT / "build" / "patch" / dynamic.VERSION
dynamic.BIOS_MPR_TRANSFER = True
dynamic.BIOS_DESTINATION_MPR = 4
dynamic.HELPER_EXEC_MPR_MASK = 0x20
dynamic.HELPER = 0xBCD2
dynamic.HELPER_LIMIT = 0xC000


if __name__ == "__main__":
    dynamic.main()
