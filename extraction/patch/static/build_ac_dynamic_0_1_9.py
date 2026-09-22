#!/usr/bin/env python3
"""Build ac_0.1.9 with independently resident speaker/UI/shared packs."""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(r"C:\snatcher")
STATIC = ROOT / "extraction" / "patch" / "static"
sys.path.insert(0, str(STATIC))

import build_ac_dynamic_0_1_5 as dynamic  # noqa: E402


def classify_split_common(row: dict[str, str]) -> str:
    if row["kind"] == "speaker":
        return "speaker"
    if row["kind"] == "ui":
        return "ui"
    blocks: list[str] = []
    for reference in row["reference"].split(","):
        match = re.match(r"([0-9A-F]{6}):", reference)
        if match and match.group(1) not in blocks:
            blocks.append(match.group(1))
    if not blocks:
        return "runtime"
    if len(blocks) > 1:
        return "shared"
    return f"scene_{blocks[0]}"


dynamic.VERSION = "ac_0.1.9"
dynamic.OUT = ROOT / "build" / "patch" / dynamic.VERSION
dynamic.BIOS_MPR_TRANSFER = True
dynamic.BIOS_DESTINATION_MPR = 4
dynamic.HELPER_EXEC_MPR_MASK = 0x20
dynamic.HELPER = 0xBCD2
dynamic.HELPER_LIMIT = 0xC000
dynamic.RESIDENT_PACK_NAMES = ("speaker", "ui", "shared")
dynamic.classify = classify_split_common


if __name__ == "__main__":
    dynamic.main()
