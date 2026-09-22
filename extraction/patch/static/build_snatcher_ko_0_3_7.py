"""Snatcher Korean patch — 0.3.7.  런타임 마스터로 만든 첫 판.

0.3.6 과 런타임 동작이 같다.  바뀐 것은 **입력**이다.

    마스터   정적 추출 7,204행  ->  런타임 관측 1,473행 / 840 레코드
    레코드   2,596  ->  훨씬 적다.  수집한 만큼만 들어 있다

그래서 이 디스크는 **한글이 줄어든다.**  고장이 아니라 의도다.  번역이 없는 줄은
원문 그대로 나오고, 그것이 이 판의 용도다 -- 소유자가 일본어로 문맥을 확인하면서
어디가 비었는지 눈으로 보고 수집 표적을 잡는다.

0.3.5/0.3.6 폴더는 건드리지 않는다.  이 프로젝트는 이미 제자리 덮어쓰기로 원본을
두 번 잃었다 (build_snatcher_ko_0_3_5.py 14:36, build_ac_dynamic_0_1_14.py 18:35 --
둘 다 사본 없음).  새 판은 항상 새 번호로 나간다.

Run this, not the individual stage scripts.  It pins every parameter that the
three stages used to take by hand, so a build is reproducible from the master
TSVs alone:

    python build_snatcher_ko_0_3_6.py              full build (stages 1-3)
    python build_snatcher_ko_0_3_6.py --stage3     stage 3 only, reusing stage 1/2
    python build_snatcher_ko_0_3_6.py --check      validate inputs, build nothing

0.3.6 — review progress, and the builder rules that had to bend for it
---------------------------------------------------------------------
No runtime behaviour changed from 0.3.5.  What changed is the data and two
builder rules that the growing data broke.

    records        2,481 -> 2,596   (a day of review marks)
    atlas          1,133 -> 1,155 glyphs
    packs          33 -> 27         via COALESCE_SMALL_SCENES_MAX_RECORDS 3 -> 6

**Pack ceiling.**  Scene grouping reached 33 packs, over both limits: the
hardcoded 31 for the directory's pack_id field, and the real one at 28 where the
AC state page's 8-bytes-per-pack metadata table meets the template at $10100.
Coalescing scenes of <= 6 records instead of <= 3 brings it to 27.  This is a
stopgap -- the scene split is far finer than the game's own text banks, and the
location-pack work will regroup by MPR6 (9-11 packs) once a full playthrough has
been collected.

**Context-only rows.**  `예외처리` means "this fragment reads only after the row
before it", and the builder verified that by looking for an earlier line_no of
the same text_key.  A runtime capture is keyed by the hash of its own bytes, so a
sentence cut across two records becomes two *different* text_keys -- the head is
not line_no-1, it is the previous row in the file.  Correctly marked runtime
fragments could never pass.  The check now accepts either shape.

**Data fixes that the trie refused to build over.**

    trailing spaces   51 rows.  Two translations identical except for a trailing
                      space are different strings to the trie, and invisible to
                      a reviewer
    split point       0D1800:2047 split "그럼 장 자크 깁슨의 / 환경 A로 가겠습니다"
                      at a different place than 0C9800:2664.  Same sentence, and
                      the game cannot tell the two apart
    runtime fragment  RUNTIME_01E9_DEEBB6CB (`す。`) deleted.  Short tails are
                      kept as {EMPTY}; this one carried text that collided with
                      a static row at the same trie state

0.3.5 was rebuilt in place before this number existed, so the disc in
`build\patch\0.3.5\` is **not** the one its release note describes (it has
2,596 records, not 2,481).  Its stage 1/2 intermediate is gone too.  Roll back to
0.3.4 rather than 0.3.5 if an exact known state is needed.

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

VERSION = "0.3.7"
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
PROTECTED = {VERSION, "0.3.6", "0.3.5", "0.3.4", "0.3.3", STAGE1_VERSION, "ac_0.1.14", "0.2.26"}
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
    # `SNATCHER_PRELOAD_PACKS=0 python build_snatcher_ko_0_3_6.py` still works
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
