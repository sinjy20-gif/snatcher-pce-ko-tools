#!/usr/bin/env python3
"""Build SPACE 0.1.1: Korean-only fractional word-space trial.

This leaves every translation string and all UI/speaker routing unchanged.
Only the codec's emitted byte sequence for Unicode spaces changes from the
native full-cell 81 40 to the reserved F0 41 fractional-space code.  The
direct overlay already contains the paired cursor-phase and glyph-shift
handlers for F041; this build makes that dormant path testable in isolation.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import sys

ROOT = Path(r"C:\snatcher")
STATIC = ROOT / "extraction" / "patch" / "static"
TRANS = ROOT / "extraction" / "translation"
sys.path[:0] = [str(STATIC), str(TRANS)]

import build_direct_overlay_patch as direct
import game_text_codec as codec


VERSION = "space 0.1.1"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    # Deliberately process-wide for this one build process only.  The normal
    # production builder remains unchanged and continues emitting 81 40.
    codec.COMPACT_SPACE = codec.CUSTOM_SPACE
    # Match the stable KO 0.2.23 baseline.  This keeps the experiment focused
    # on spacing and excludes unreviewed rows that may legitimately conflict
    # in the evolving master workspace.
    output = direct.build(VERSION, args.force, review_only=True)
    (output / "SPACE_TEST.txt").write_text(
        "SPACE 0.1.1\n"
        "Only Korean word spaces use F041 fractional spacing.\n"
        "Test: word gap should be visually about half the former 8140 gap;\n"
        "dialogue progression, colors, and no-space lines must remain normal.\n",
        encoding="utf-8-sig",
    )
    print(output)


if __name__ == "__main__":
    main()
