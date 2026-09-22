#!/usr/bin/env python3
"""Build SPACE 0.1.2: native one-byte $20 word-space trial.

Unlike SPACE 0.1.1 this does not use the F041 fractional cursor experiment.
It sends Korean word spaces through the game's existing single-byte $20 path,
while preserving the normal renderer, font wrapper, and cursor routines.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import sys

ROOT = Path(r"C:\\snatcher")
STATIC = ROOT / "extraction" / "patch" / "static"
TRANS = ROOT / "extraction" / "translation"
sys.path[:0] = [str(STATIC), str(TRANS)]

import build_direct_overlay_patch as direct
import game_text_codec as codec


VERSION = "space 0.1.2"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    # The renderer explicitly branches on $20.  This uses that native path;
    # no fractional cursor phase, glyph shift, or new control code is involved.
    codec.COMPACT_SPACE = codec.HALFWIDTH_SPACE
    output = direct.build(VERSION, args.force, review_only=True)
    (output / "SPACE_TEST.txt").write_text(
        "SPACE 0.1.2\n"
        "Korean word spaces emit native one-byte $20.\n"
        "Expected: a visibly narrower gap, with normal progression and no glyph corruption.\n",
        encoding="utf-8-sig",
    )
    print(output)


if __name__ == "__main__":
    main()
