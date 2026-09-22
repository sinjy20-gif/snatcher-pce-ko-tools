#!/usr/bin/env python3
"""Snatcher Korean patch — 0.3.5.  THE official entry point.

Run this, not the individual stage scripts.  It pins every parameter that the
three stages used to take by hand, so a build is reproducible from the master
TSVs alone:

    python build_snatcher_ko_0_3_5.py              full build (stages 1-3)
    python build_snatcher_ko_0_3_5.py --stage3     stage 3 only, reusing stage 1/2
    python build_snatcher_ko_0_3_5.py --check      validate inputs, build nothing

0.3.5 — half the Arcade Card traffic per record
-----------------------------------------------
0.3.4 fixed three causes of the abandoned-factory flicker (see its own docstring
and docs\handoff\SNATCHER_UI_FLICKER_HANDOFF_2026-08-14.md).  What was left is
CPU *occupancy*: the game reloads its scroll every 10-12 scanlines by polling,
so a helper that holds the CPU across one of those updates pushes it a line
late.  It is a probability, not a threshold -- shorter occupancy, fewer
collisions.

Two pieces of the per-record work turned out to be moving bytes for nothing.

    constants        The 96-byte const run was re-laid on every record even
                     though only this transfer writes $5BE0-$5C3F.  Now two
                     sentinel bytes are checked first: ~14 cycles when intact,
                     and the copy still runs (repairing in the same record) when
                     they are not.
    stale slots      The blank ran over every slot the previous record used --
                     and the glyph loop then refilled most of them.  Now the
                     glyph loop clears a slot only when this record has no glyph
                     for it and the previous record did.

Measured on the abandoned factory, same route both runs:

    0.3.4        178 records, 101,936 AC port reads   573 per record
    0.3.5        129 records,  45,989 AC port reads   357 per record   -38%

    transfer time  7.6 -> 4.7 scanlines (+ ~0.9 fixed overhead)

Confirmed three independent ways: the port-read count above, a visibly narrower
Arcade band in Mesen's Event Viewer, and the owner seeing fewer displacements.

Boot also drops.  SNATCHER_PRELOAD_PACKS now defaults to "resident" -- the four
resident packs (35 chunks) rather than all 25 (52 chunks).  The stalls that
motivated full preloading came from the 122 KB ui pack arriving on demand;
scene packs average 5.8 KB and are cheap to fetch when first needed.

What is NOT fixed
-----------------
Flicker still appears.  It is a collision probability between our occupancy and
the game's scroll reload, and 4.7 scanlines is not 0.  What remains to move is
the glyph data itself -- one syllable is 32 bytes and has to arrive once -- so
the code side is close to its floor.  A record using 12 distinct syllables still
costs 384 bytes of that.

Never measured: helper entry-to-return in real cycles (PROBE 0.3.5 census, both
runs were stopped before Stop).  That number decides whether the remaining lever
is code at all.  It is the first thing to collect if this is picked up again.

Rolling back
------------
Every stage is shared with 0.3.3, so a rollback is a one-line choice, not a
revert:

    python build_snatcher_ko_0_3_4.py             0.3.4 exactly as it shipped
    python build_snatcher_ko_0_3_3.py             0.3.3 exactly as it shipped
    SNATCHER_PRELOAD_PACKS=all ...                every pack up front (slower boot)
    SNATCHER_PRELOAD_PACKS=none ...               nothing preloaded
    SNATCHER_TAI_CHUNK=608 ...                    without the TAI split

`build\\patch\\0.3.3\\` is PROTECTED and still has its payload, so the old disc
can also just be played.

Do NOT reach for the faster variants built on 2026-08-14 (`noblank`, `both`,
`lean`, `lean2`).  They drop the glyph blanking, which costs a record whose text
references a trailing blank slot: the previous line's syllable stays on screen.
It is rare enough to pass a short test and still reach players.

Version history behind this number
----------------------------------
The engine is the verified ``0.3.0-uitest`` renderer.  ``ac_0.1.1`` through
``ac_0.1.18`` were the Arcade Card backing-store development series on top of
it; ``ac_0.1.14`` was the last one.  0.3.0 promoted that combination to the
project's single version number; 0.3.1 fixed the AC layout, 0.3.2 gave each
scene pack its own address, 0.3.3 froze the pipeline, and 0.3.4 is the flicker
work above.

What is frozen
--------------
    engine            0.3.0-uitest renderer.  $66E5 hook, $5E40 preloader,
                      $7F50 font wrapper, $5B80-$5E3F 704 B cache.  Do not
                      redesign these.
    record format     128 B compact record + global glyph atlas, expanded back
                      to a byte-identical 704 B payload by the Bank 69 helper
    CHUNK_BYTES       8 KiB.  Hard ceiling — above it the BIOS loses the AC
                      auto-increment pointer at a bank boundary
    stage 1 base      ac_0.1.11-source (intermediate, not a release)
    inclusion         BODY: first unnamed review column is O (예외처리 = context
                      -only continuation).  UI: review column is O.
                      ko_text or status alone never ships a row.

Inputs — the only canonical ones
--------------------------------
    snatcher_tool/translation/snatcher_ko_master.tsv
    snatcher_tool/translation/ui_text.tsv
    snatcher_tool/translation/speaker_name_standard.tsv

Edit them through SnatcherTranslationStudio.exe.  Close Studio before touching
them from outside, or Studio will write back its stale review column on save.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

STATIC = Path(__file__).resolve().parent
ROOT = STATIC.parents[2]
sys.path.insert(0, str(STATIC))

VERSION = "0.3.5"
STAGE1_VERSION = "ac_0.1.11-source"
STAGE1_BUILD = ROOT / "build" / "patch" / STAGE1_VERSION
OUT = ROOT / "build" / "patch" / VERSION

TRANSLATION = ROOT / "snatcher_tool" / "translation"
CANONICAL_INPUTS = (
    TRANSLATION / "snatcher_ko_master.tsv",
    TRANSLATION / "ui_text.tsv",
    TRANSLATION / "speaker_name_standard.tsv",
    # Stage 3 copies this into the build folder as a provenance record, so a
    # missing file fails the build at the very last step.
    TRANSLATION / "master_conflict_exclusions.tsv",
)

# 0.3.4's defaults, set here rather than left to whoever remembers the export.
# A build has to be reproducible from this file alone.
DEFAULTS = {
    "SNATCHER_PRELOAD_PACKS": "resident",  # ui/speaker/shared up front
    "SNATCHER_TAI_CHUNK": "76",      # 1.04 scanlines of IRQ block, not 8.05
    "SNATCHER_BLANK_SLOTS": "1",     # bounded blanking; 0 leaves stale glyphs
}

# Names refused even when named explicitly.  0.3.3 stays playable as the
# rollback target, 0.2.26 is the BODY control build, and the other two are what
# the current build stands on.
PROTECTED = {VERSION, "0.3.4", "0.3.3", STAGE1_VERSION, "ac_0.1.14", "0.2.26"}
PAYLOAD_SUFFIXES = (".bin", ".chd")


def prune(names: list[str], deep: bool = False) -> None:
    """Delete disc payloads from the named builds, keeping their records.

    Standing rule from the project owner: **no build is ever pruned unless he
    has called that build an experiment.**  The caller has to name what goes,
    so nothing goes by default.
    """
    targets = set(names) | ({STAGE1_VERSION} if deep else set())
    if not targets:
        raise SystemExit(
            "--prune needs the build folders to drop, e.g.\n"
            f"    --prune {VERSION}-base {VERSION}-experiment\n"
            "No build is pruned unless it is named an experiment.")
    guarded = targets & PROTECTED
    if guarded:
        raise SystemExit(f"refusing to prune protected build(s): "
                         f"{', '.join(sorted(guarded))}")
    root = ROOT / "build" / "patch"
    # Experiments live under EXPERIMENT\ since 2026-08-15, and they are the only
    # thing this is ever pointed at, so look one level down as well.
    candidates = [p for p in root.iterdir() if p.is_dir()]
    experiment = root / "EXPERIMENT"
    if experiment.is_dir():
        candidates += [p for p in experiment.iterdir() if p.is_dir()]
    freed = unlinked = 0
    for build in sorted(candidates):
        if build.name not in targets:
            continue
        for path in sorted(build.rglob("*")):
            if not path.is_file() or path.suffix.lower() not in PAYLOAD_SUFFIXES:
                continue
            stat = path.stat()
            # A hardlinked track shares its inode with rom(japan), so removing
            # this name frees nothing.  Drop it anyway to keep the folder
            # honest, but do not claim the bytes back.
            if stat.st_nlink > 1:
                unlinked += 1
            else:
                freed += stat.st_size
            path.unlink()
    if freed or unlinked:
        print(f"pruned {freed / 1e6:,.0f} MB "
              f"({unlinked} hardlinked track names also dropped) from "
              f"{', '.join(sorted(targets))}")


def check_inputs() -> None:
    missing = [p for p in CANONICAL_INPUTS if not p.exists()]
    if missing:
        raise SystemExit(
            "missing canonical input(s):\n  "
            + "\n  ".join(str(p) for p in missing)
        )

    sys.path.insert(0, str(ROOT / "extraction" / "translation"))
    import build_full_overlay_layout as layout
    from tsv_io import read_dict_rows

    selected, exceptions = layout.reviewed_row_ids(TRANSLATION / "snatcher_ko_master.tsv")
    ui_header, ui_rows = read_dict_rows(TRANSLATION / "ui_text.tsv")
    review = layout.ui_review_column(ui_header)
    ui_ok = [r for r in ui_rows
             if r.get("ko_text", "").strip()
             and r.get("status", "") != "skip"
             and layout.is_ui_reviewed(r, review)]
    ui_translated = [r for r in ui_rows if r.get("ko_text", "").strip()]

    print(f"BODY  reviewed rows : {len(selected):,} (예외처리 {len(exceptions)})")
    print(f"UI    review column : {review!r}")
    print(f"UI    translated    : {len(ui_translated):,} / {len(ui_rows):,}")
    print(f"UI    review = O    : {len(ui_ok):,}   <- this is what ships")
    if ui_translated and not ui_ok:
        print()
        print("  NOTE: every UI row is unreviewed, so this build ships 0 UI labels.")


def stage(argv: list[str], title: str) -> None:
    print(f"\n=== {title} ===", flush=True)
    # Pin the translator workspace rather than trusting the ambient default.
    env = dict(os.environ, SNATCHER_TRANSLATION_DIR=str(TRANSLATION))
    result = subprocess.run([sys.executable, *argv], cwd=str(ROOT), env=env)
    if result.returncode != 0:
        raise SystemExit(f"{title} failed (exit {result.returncode})")


def main() -> None:
    global VERSION, OUT, STAGE1_VERSION, STAGE1_BUILD

    parser = argparse.ArgumentParser(description=f"build Snatcher KO {VERSION}")
    parser.add_argument("--stage3", action="store_true",
                        help="rebuild only stage 3, reusing the existing "
                             f"{STAGE1_VERSION} intermediate")
    parser.add_argument("--check", action="store_true",
                        help="report what would ship, then stop")
    parser.add_argument("--prune", nargs="*", metavar="BUILD",
                        help="delete the named builds' disc payload, then stop. "
                             "Name only builds the owner has called experiments "
                             "-- nothing is pruned by default")
    parser.add_argument("--deep", action="store_true",
                        help=f"with --prune, also drop the {STAGE1_VERSION} "
                             "intermediate (costs the next build its --stage3)")
    parser.add_argument("--space", choices=("8140", "F041", "20"), default="8140",
                        help="byte sequence a Korean word space compiles to. "
                             "8140 = native full cell (default, what ships). "
                             "F041 = reserved fractional space, two per cursor "
                             "unit. 20 = the renderer's single-byte space "
                             "branch. Non-default values build into a suffixed "
                             "folder and are experiments, not releases.")
    parser.add_argument("--tag", default="",
                        help="suffix the build and its stage 1/2 intermediate "
                             "with this name. Use it when the experiment is in "
                             "the translation data rather than in a flag, so "
                             "the release folder is never overwritten.")
    args = parser.parse_args()

    # Apply 0.3.4's defaults without clobbering a deliberate override, so
    # `SNATCHER_PRELOAD_PACKS=0 python build_snatcher_ko_0_3_5.py` still works
    # as the documented rollback.
    for name, value in DEFAULTS.items():
        os.environ.setdefault(name, value)
    changed = {n: os.environ[n] for n, v in DEFAULTS.items() if os.environ[n] != v}
    if changed:
        print("non-default runtime options: "
              + ", ".join(f"{n}={v}" for n, v in sorted(changed.items())))

    suffix = ""
    if args.space != "8140":
        os.environ["SNATCHER_KO_SPACE"] = args.space
        suffix += f"-space{args.space}"
        print(f"space experiment: Korean word spaces compile to {args.space}")
    if args.tag:
        suffix += f"-{args.tag}"

    if suffix:
        # Keep the release build untouched: an experiment gets its own folder
        # and its own name so a stray disc can never be mistaken for a release.
        #
        # And it goes under EXPERIMENT\, not beside the releases.  By 2026-08-15
        # there were 60 experiment folders sitting next to four real builds and
        # the owner could not tell them apart at a glance.
        VERSION = f"{VERSION}{suffix}"
        STAGE1_VERSION = f"{STAGE1_VERSION}{suffix}"
        OUT = ROOT / "build" / "patch" / "EXPERIMENT" / VERSION
        STAGE1_BUILD = ROOT / "build" / "patch" / "EXPERIMENT" / STAGE1_VERSION
        OUT.parent.mkdir(parents=True, exist_ok=True)
        PROTECTED.update({VERSION, STAGE1_VERSION})
        print(f"  stage 1/2 -> {STAGE1_BUILD}")
        print(f"  output    -> {OUT}")

    if args.prune is not None:
        prune(args.prune, deep=args.deep)
        return

    check_inputs()
    if args.check:
        return

    if args.stage3:
        if not STAGE1_BUILD.exists():
            raise SystemExit(
                f"--stage3 needs {STAGE1_BUILD}, which is missing. "
                "Run without --stage3 to regenerate it.")
        print(f"\nreusing stage 1/2 intermediate: {STAGE1_BUILD}")
    else:
        stage([str(STATIC / "build_direct_overlay_patch_ui.py"),
               "--version", STAGE1_VERSION, "--review-only", "--force"],
              "stage 1  master -> 704 B SRT4 records")
        stage([str(STATIC / "build_ac_backing_store.py"),
               "--build", str(STAGE1_BUILD)],
              "stage 2  sparse slots -> dense record image")

    print("\n=== stage 3  compact 128 B + atlas + AC packs + disc ===", flush=True)
    import build_ac_dynamic_0_1_14 as stage3

    # Same wrapper pattern the AC series used: retarget the shared dynamic
    # module, then run the pinned stage 3.
    dynamic = stage3.dynamic
    dynamic.VERSION = VERSION
    dynamic.OUT = OUT
    dynamic.BASE = STAGE1_BUILD
    stage3.main()

    print(f"\n{VERSION} -> {OUT}")


if __name__ == "__main__":
    main()
