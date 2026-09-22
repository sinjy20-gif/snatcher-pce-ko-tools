"""Build the production Track-24 lookup and per-line Korean assets.

The runtime never rewrites the original script.  At the renderer hand-off it
matches the completed Japanese buffer against one of 1024 small fingerprint
buckets.  The build rejects every ambiguous fingerprint before producing a
patch, so the runtime can use compact fixed-size records without losing the
exact source/context routing established by the extractor.  A successful
record names one Track-24 asset sector containing both
the replacement string and the complete one-line font pack required to draw
it.  This keeps every CD read outside the per-glyph rendering loop.

Layout (MODE1 user data):

* 1024 lookup sectors, selected by a cheap 10-bit byte sum of the source.
* one asset sector per distinct Korean renderer string.
* each asset is loaded at CPU $5B80; text begins at $5B90 and its 608-byte
  font cache begins at $5BE0, ending immediately before code at $5E40.

Speaker names and UI labels use wildcard-state records.  Narrative lines use
a compact trie state so repeated Japanese fragments can retain their intended
translation without storing or hashing the complete preceding script.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import os
import shutil
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path


ROOT = Path(r"C:\snatcher")
TRANSLATION_DIR = ROOT / "extraction" / "translation"
STATIC_DIR = ROOT / "extraction" / "patch" / "static"
# The canonical workspace is the one Studio writes.  It used to default to
# ROOT/"translation", a mirror that no longer exists, so an unset
# SNATCHER_TRANSLATION_DIR silently resolved every master path to a missing file.
TRANSLATOR_WORKSPACE = Path(os.environ.get(
    "SNATCHER_TRANSLATION_DIR", ROOT / "snatcher_tool" / "translation"))
DEFAULT_MASTER = TRANSLATOR_WORKSPACE / "snatcher_ko_master.tsv"
DEFAULT_SPEAKERS = TRANSLATOR_WORKSPACE / "speaker_name_standard.tsv"
DEFAULT_UI = TRANSLATOR_WORKSPACE / "ui_text.tsv"
DEFAULT_COMPILED = ROOT / "build" / "translation" / "current" / "compiled"
DEFAULT_OUT = ROOT / "build" / "translation" / "current" / "runtime_layout"
FONT_BDF = ROOT / "extraction" / "font_research" / "Galmuri11.bdf"

sys.path[:0] = [str(TRANSLATION_DIR), str(STATIC_DIR)]

import build_track24_loader_proof as track24  # noqa: E402
from build_disc_patch import glyph_1bpp_left_shifted, parse_bdf  # noqa: E402
from compile_overlay_assets import SourceRow, read_rows  # noqa: E402
from game_text_codec import (  # noqa: E402
    HANGUL_CODES,
    encode_game_text,
    ordered_hangul,
)
from layout_markup import FE_TOKEN_RE  # noqa: E402
from source_text_markup import encode_source_text  # noqa: E402
from tsv_io import read_dict_rows  # noqa: E402


BUCKET_COUNT = 1024
BUCKET_HEADER_SIZE = 8
RECORD_SIZE = 9
WILDCARD_STATE = 0xFFFF

# 대사창 한 페이지에 들어가는 줄 수 (화자명 줄 포함).  이 수를 채우면 페이지가
# 넘어가고 화자명이 다시 찍히면서 런타임 state 가 루트로 떨어진다.
PAGE_LINES = 3
ASSET_HEADER_SIZE = 0x10
# Asset-cache addresses are also used by the original font/render path.
# Keep the verified SRT4 layout intact: text at $5B90 and a 608-byte font
# cache at $5BE0, ending immediately before runtime code at $5E40.
ASSET_TEXT_CAPACITY = 0x50
ASSET_FONT_OFFSET = 0x60
# BIOS 폰트 경로 (SNATCHER_KO_BIOS=1).  한글이 시스템 카드 글리프로 나가므로
# 레코드에 우리 글리프를 실을 이유가 없다.  이 스위치가 켜지면 줄마다 굽던 한글
# 래스터를 통째로 건너뛴다 -- 15 자 예산도 아틀라스도 글리프 루프도 여기서 죽는다.
# 상수 3 칸(마침표 F040 / 공백 F041 / 말줄임 F042)과 반칸 도우미는 그대로 남는다.
BIOS_HANGUL = os.environ.get("SNATCHER_KO_BIOS", "0").strip() == "1"

FONT_GLYPH_CAPACITY = 19
FONT_BYTES = FONT_GLYPH_CAPACITY * 32
ASSET_READ_BYTES = ASSET_FONT_OFFSET + FONT_BYTES
# The final 32-byte font slot is executable Card-RAM in the live cache.  Every
# asset carries the same helper so a font-pack CD read cannot overwrite it.
# F041 toggles a persistent half-cell phase; every second space commits one
# native cursor unit.  Returning A=$347F matches the original $685E routine.
FRACTIONAL_SPACE_HELPER_INDEX = FONT_GLYPH_CAPACITY - 1
FRACTIONAL_SPACE_HELPER = bytes.fromhex(
    "A5 F9 C9 F0 D0 17 A5 F8 C9 41 D0 11 "
    "AD 70 34 49 80 8D 70 34 30 03 EE 7A 34 "
    "AD 7F 34 60 4C 5E 68"
)
if len(FRACTIONAL_SPACE_HELPER) != 32:
    raise RuntimeError("fractional-space helper must fill one 32-byte slot")
ALLOWED_STATUS = {"ai_draft", "draft", "review", "final"}


def ui_review_column(header: list[str]) -> str:
    """Return the key of the UI review column, matching the BODY convention.

    BODY marks a reviewed row with ``O`` in the first unnamed column.  The UI
    sheet gained the same axis on 2026-08-12, so prefer an unnamed column and
    fall back to an explicitly named ``review`` one.  A UI label lives in a
    fixed number of cells (the action menu is 8 cells of 8 characters), so
    "translated" and "verified on screen" are genuinely different states and
    ``status`` cannot stand in for the review mark.
    """

    for name in header:
        if not (name or "").strip():
            return name
    for name in header:
        if (name or "").strip().lower() == "review":
            return name
    raise RuntimeError(
        "ui_text.tsv needs a review column: either a first unnamed column or "
        "one named 'review'. Mark verified rows with O."
    )


def is_ui_reviewed(row: dict[str, str], column: str) -> bool:
    """A UI row ships only when its review column is O."""

    return (row.get(column) or "").strip().upper() == "O"


# Does 예외처리 still ship a row?
#
# It was a second shipping mark next to O: a continuation fragment that reads
# only after the row before it, kept out of the root state so a generic tail
# (``ます。``) could not become a global replacement.  The runtime-keyed master
# rebuild (2026-08-16) removes the need -- a tail row now either carries its own
# text or is absorbed into the head with {EMPTY} -- and the owner is re-reviewing
# those rows by hand, so the mark ships nothing until he marks it O.
#
# 0.3.3-0.3.7 were built while it did ship.  SNATCHER_REVIEW_EXCEPTIONS=1
# restores that, which is what reproducing those discs needs.
REVIEW_EXCEPTIONS = os.environ.get("SNATCHER_REVIEW_EXCEPTIONS", "0") == "1"

# 2026-09-01: 원문 시퀀스가 같아서 번역이 통일되는 것을 **에러로 세울지**.
# 기본은 경고만 (지금 빌드를 막지 않는다).  1 이면 뿌리 충돌과 같은 대우.
STRICT_UNIFY = os.environ.get("SNATCHER_STRICT_UNIFY", "0") == "1"


def _safe(text: str) -> str:
    """콘솔 인코딩으로 못 찍는 글자를 지운다.

    빌드는 하위 프로세스로 도는데 그 stdout 이 cp949 다.  일본어 원문에는
    `・`(U+30FB) 처럼 cp949 에 없는 글자가 있어서, 경고문이 원문을 그대로 찍으면
    **UnicodeEncodeError 로 빌드가 죽는다** (2026-09-01 에 두 번 밟았다).
    경고 때문에 빌드가 죽는 것은 본말전도이므로 여기서 걸러 찍는다.
    """

    encoding = getattr(sys.stdout, "encoding", None) or "utf-8"
    return text.encode(encoding, "replace").decode(encoding, "replace")

# 2026-09-01: trie 충돌이 나면 **첫 건에서** 죽는다.  한 건 고치고 십 분짜리
# 빌드를 다시 도는 일이 반복되므로, 1 이면 전부 모아서 한 번에 보고하고 죽는다.
# (고치는 방법은 스튜디오에서 한쪽을 `예외처리` 로 바꾸는 것이다 -- 기본값에서
#  예외처리 행은 안 실린다)
TRIE_REPORT = os.environ.get("SNATCHER_TRIE_REPORT", "0") == "1"
# 1 이면 첫 넘침에서 죽지 않고 버킷 사용량 분포를 다 찍는다.
BUCKET_REPORT = os.environ.get("SNATCHER_BUCKET_REPORT", "0") == "1"


def reviewed_row_ids(master: Path) -> tuple[set[tuple[str, int]], set[tuple[str, int]]]:
    """Return reviewed rows and the subset requiring context-only handling.

    ``O`` is an ordinary reviewed row. ``예외처리`` marks a continuation
    fragment whose Korean text is valid only after the preceding rows of the
    same text_key (for example a generic Japanese suffix such as ``ています。``).
    Those rows must remain in the dialogue trie at a nonzero state and must
    never be promoted to a global/root replacement.
    """

    raw = master.read_bytes()
    encoding = "utf-16" if raw.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8-sig"
    reader = csv.reader(io.StringIO(raw.decode(encoding)), delimiter="\t")
    header = next(reader)
    try:
        review_column = next(index for index, name in enumerate(header) if not name.strip())
    except StopIteration as exc:
        raise RuntimeError("review-only build requires an unnamed O review column") from exc

    text_key_column = header.index("text_key")
    line_no_column = header.index("line_no")
    selected: set[tuple[str, int]] = set()
    exceptions: set[tuple[str, int]] = set()
    # A runtime capture is keyed by the hash of its own bytes, so a sentence cut
    # across two records becomes two *different* text_keys -- the head is not
    # line_no-1 of the same key, it is the previous row in the file.  The
    # same-key rule below therefore cannot be satisfied by them, however
    # correctly they are marked.  Record the file-order predecessor as well so
    # the caller can accept either shape.
    previous_id: tuple[str, int] | None = None
    file_order_predecessor: dict[tuple[str, int], tuple[str, int]] = {}

    for row_number, row in enumerate(reader, start=2):
        if not any(value.strip() for value in row):
            continue
        try:
            row_id = (row[text_key_column], int(row[line_no_column]))
        except (IndexError, ValueError) as exc:
            raise RuntimeError(f"invalid reviewed row at TSV line {row_number}") from exc
        mark = row[review_column].strip() if review_column < len(row) else ""
        if mark.upper() == "O":
            selected.add(row_id)
        elif mark == "예외처리" and REVIEW_EXCEPTIONS:
            selected.add(row_id)
            exceptions.add(row_id)
            if previous_id is not None:
                file_order_predecessor[row_id] = previous_id
        previous_id = row_id

    reviewed_row_ids.file_order_predecessor = file_order_predecessor
    return selected, exceptions


def read_reviewed_source_rows(
    master: Path,
    selected: set[tuple[str, int]],
) -> list[SourceRow]:
    """Read only visible Studio-reviewed translations.

    The full recovery master intentionally contains unclassified one-row
    RUNTIME captures whose control is CONT.  They are future source material,
    not production input, and must not make an O-only build validate or include
    them.  Row order and the original immutable text_key/line_no identities are
    retained.
    """

    _, raw_rows = read_dict_rows(master)
    rows: list[SourceRow] = []
    seen: set[tuple[str, int]] = set()
    for file_line, row in enumerate(raw_rows, start=2):
        if not any(value.strip() for value in row.values()):
            continue
        try:
            identity = (row["text_key"], int(row["line_no"]))
        except (KeyError, ValueError) as exc:
            raise RuntimeError(f"invalid master identity at TSV line {file_line}") from exc
        if identity not in selected or not row.get("ko_text", ""):
            continue
        if identity in seen:
            raise RuntimeError(f"duplicate reviewed identity: {identity[0]}:{identity[1]}")
        seen.add(identity)
        control = row.get("after_control", "")
        if control not in {"BR", "PAGE", "CONT", "END"}:
            raise RuntimeError(f"invalid reviewed control {control!r}: {identity[0]}:{identity[1]}")
        rows.append(
            SourceRow(
                text_key=identity[0],
                line_no=identity[1],
                after_control=control,
                status=row.get("status", ""),
                jp_text=row.get("jp_text", ""),
                ko_text=row.get("ko_text", ""),
                note=row.get("note", ""),
                pack=row.get("pack", ""),
                speaker=row.get("speaker", ""),
                root_mode=row.get("root_mode", ""),
            )
        )
    return rows


def normalize_reviewed_root_conflicts(rows: list[SourceRow]) -> tuple[list[SourceRow], int]:
    """Reject unresolved root conflicts instead of silently flattening them.

    ``root_mode=AUTO`` rows are deliberately absent from the global root: the
    trie builder places them under their captured pack/speaker context.  Every
    other byte-identical root must already have one explicit Korean value.
    """

    first_line_by_key: dict[str, int] = {}
    for row in rows:
        first_line_by_key.setdefault(row.text_key, row.line_no)

    chosen: dict[bytes, tuple[str, str]] = {}
    conflicts: list[tuple[str, str, str, str]] = []
    for row in rows:
        if row.line_no != first_line_by_key[row.text_key]:
            continue
        # ★ PAGE 는 여기서 빼지 않는다 -- 전역 뿌리에 올라가므로 다른 뿌리와
        #   똑같이 충돌 검사를 받아야 한다.  팩 방으로 내려가는 것만 뺀다.
        if row.root_mode.strip().upper() in CONTEXT_MODES:
            continue
        source = encode_source_text(row.jp_text)
        ref = f"{row.text_key}:{row.line_no}"
        previous = chosen.setdefault(source, (row.ko_text, ref))
        if previous[0] != row.ko_text:
            conflicts.append((previous[1], ref, previous[0], row.ko_text))
    if conflicts:
        details = "\n".join(
            f"  {first} {first_ko!r} != {second} {second_ko!r}"
            for first, second, first_ko, second_ko in conflicts[:20]
        )
        raise RuntimeError(
            f"unresolved root translations: {len(conflicts)} rows; "
            "use root_mode=AUTO or explicitly unify them\n" + details
        )
    return rows, 0


def normalize_identical_reviewed_sequences(
    rows: list[SourceRow],
    exceptions: set[tuple[str, int]],
) -> tuple[list[SourceRow], int]:
    """Unify translations for byte-identical complete Japanese sequences.

    The renderer cannot distinguish two occurrences whose complete ordered
    Japanese fragments and controls are identical.  Prefer the reviewed
    sequence containing an explicit context-only marker, then use that same
    Korean sequence for every identical occurrence.
    """

    groups: dict[str, list[SourceRow]] = defaultdict(list)
    key_order: list[str] = []
    for row in rows:
        if row.text_key not in groups:
            key_order.append(row.text_key)
        groups[row.text_key].append(row)
    for members in groups.values():
        members.sort(key=lambda item: item.line_no)

    by_signature: dict[tuple[tuple[bytes, str], ...], list[str]] = defaultdict(list)
    for text_key in key_order:
        signature = tuple(
            (encode_source_text(row.jp_text), row.after_control)
            for row in groups[text_key]
        )
        by_signature[signature].append(text_key)

    canonical_by_key: dict[str, list[SourceRow]] = {}
    for keys in by_signature.values():
        canonical_key = next(
            (
                key for key in keys
                if any((row.text_key, row.line_no) in exceptions for row in groups[key])
            ),
            keys[0],
        )
        canonical = groups[canonical_key]
        for key in keys:
            canonical_by_key[key] = canonical

    canonical_ref: dict[str, str] = {}
    for keys in by_signature.values():
        canonical = canonical_by_key[keys[0]]
        for key in keys:
            canonical_ref[key] = f"{canonical[0].text_key}:{canonical[0].line_no}"

    normalized: list[SourceRow] = []
    changed = 0
    # ★ 2026-09-01: 여기서 일어나는 통일은 그동안 **아무 흔적도 안 남겼다.**
    #   원문 시퀀스가 통째로 같은 레코드끼리 번역을 하나로 맞추는데, 조용히
    #   지나가니 소유자는 자기가 쓴 번역이 남의 것으로 덮였는지 알 방법이 없었다
    #   (실제로 머리줄 71 종이 그렇게 굳었다).  이제 무조건 보고한다.
    silenced: list[tuple[str, str, str, str, str]] = []
    position_by_key: dict[str, int] = defaultdict(int)
    for row in rows:
        position = position_by_key[row.text_key]
        position_by_key[row.text_key] += 1
        replacement = canonical_by_key[row.text_key][position].ko_text
        if replacement == row.ko_text:
            normalized.append(row)
            continue
        silenced.append((
            f"{row.text_key}:{row.line_no}", row.jp_text, row.ko_text,
            replacement, canonical_ref.get(row.text_key, "?"),
        ))
        normalized.append(
            SourceRow(
                text_key=row.text_key,
                line_no=row.line_no,
                after_control=row.after_control,
                status=row.status,
                jp_text=row.jp_text,
                ko_text=replacement,
                note=row.note,
                pack=row.pack,
                speaker=row.speaker,
                root_mode=row.root_mode,
            )
        )
        changed += 1

    if silenced:
        print(f"\n[!] 원문 시퀀스가 같아 번역을 통일했다 -- {len(silenced)} 행 "
              f"(원문 {len({item[1] for item in silenced})} 종)", flush=True)
        print("  이 줄들은 **네가 쓴 번역이 다른 레코드 것으로 바뀐 것**이다.", flush=True)
        for ref, jp, mine, forced, winner in silenced[:12]:
            print(_safe(f"    {ref:<14s} 「{jp[:24]}」"), flush=True)
            print(_safe(f"        「{mine[:30]}」 -> 「{forced[:30]}」"
                        f"  (기준 {winner})"), flush=True)
        if len(silenced) > 12:
            print(f"    … 그 외 {len(silenced) - 12} 행."
                  "  전체 목록: python tools/check_master_conflicts.py", flush=True)
        print("  갈라놓으려면 그 줄에 root_mode=AUTO + pack(16진) [+ speaker] 를 준다.", flush=True)
        if STRICT_UNIFY:
            raise RuntimeError(
                f"silent unification of {len(silenced)} rows; "
                "SNATCHER_STRICT_UNIFY=0 으로 끄거나 root_mode=AUTO 로 갈라놓을 것")
    return normalized, changed


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def hash10(data: bytes) -> int:
    """Return the runtime's intentionally cheap 10-bit source checksum."""

    return sum(data) & 0x3FF


def source_fingerprint(data: bytes) -> tuple[int, int, int]:
    """Return the compact signature reproduced by the HuC6280 runtime.

    The bucket already carries the low ten bits of the byte sum.  Length, XOR,
    and cumulative byte sum independently disambiguate every applicable
    state/source pair in the current complete translation corpus.
    """

    xor_value = 0
    running = 0
    cumulative = 0
    for value in data:
        xor_value ^= value
        running = (running + value) & 0xFF
        cumulative = (cumulative + running) & 0xFF
    return len(data), xor_value, cumulative


def write_tsv(path: Path, rows: list[dict[str, str]]) -> None:
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=list(rows[0]),
            delimiter="\t",
            lineterminator="\n",
        )
        writer.writeheader()
        writer.writerows(rows)


@dataclass
class Transition:
    source: bytes
    ko_text: str
    child: int | None = None
    refs: list[str] = field(default_factory=list)


@dataclass(frozen=True)
class RuntimeRecord:
    state: int
    next_state: int
    source: bytes
    ko_text: str
    kind: str
    ref: str


PACK_STATE_BASE = 0x0100
CONTEXT_STATE_BASE = 0x0200

# root_mode 로 머리줄을 전역 뿌리에서 내리는 두 가지 (2026-09-01)
#
#   AUTO   pack + speaker.  (pack,화자) 전용 방을 판다.  도달 경로가 **게임이
#          실제로 그리는 일본어 화자명** 이므로 `speaker` 열이 그 이름과 맞아야
#          한다.  틀리면 그 방에 영영 도달하지 못해 번역이 안 뜬다
#          (실측: R08187 은 제이미 대사인데 화자 열이 미카였다).
#   PACK   pack 만.  $0100|pack 팩 방으로 간다.  화자명을 안 거치므로
#          `speaker` 열이 틀려 있어도 안전하다.  원문이 같아도 팩이 다르면
#          이것만으로 갈린다 -- 지금 굳어 있는 머리줄 대부분이 여기 해당한다.
CONTEXT_MODES = ("AUTO", "PACK")

#   PAGE   ★2026-09-05.  "게임은 이 줄을 **새로 읽는다**" 는 표시.
#
#          아래 트라이는 페이지 경계를 `(line_no - 1) // PAGE_LINES` 로 센다.
#          PAGE_LINES 는 3 -- 대사 창 높이다.  사전 창은 그 격자와 안 맞아서,
#          게임이 뿌리에서 묻는 줄을 빌더가 사슬에 등록해 버리는 자리가 생긴다.
#          그런 줄은 런타임이 영영 못 찾아 화면에 일본어가 그대로 남는다
#          (게다가 한자 자리를 한글 글리프가 가져갔으므로 깨져 보인다).
#
#          PAGE_LINES 를 통째로 바꾸면 안 걸리던 줄까지 다 흔들린다.  그래서
#          **줄 하나씩** 재우는 손잡이를 둔다.  이 줄에서 state 를 0 으로
#          떨어뜨리고 **거기 그대로 둔다** -- 전역 뿌리다.
#
#          ★첫 판(0.5.8)은 여기서 `contextual_root()` 를 태워 팩 방
#            ($0100|0x76) 으로 보냈다.  조회표에는 state=0176 으로 잘 들어갔는데
#            **실기에서 여전히 일본어가 떴다.**  게임이 그 자리에서 팩 방을
#            안 들른다는 뜻이다 (팩 방은 화자 레코드를 거쳐 도달하는 자리다).
#            런타임이 확실히 되짚는 자리는 state 0 뿐이므로 (빌더 주석:
#            "the runtime retries from state zero") 거기에 둔다.
#
#          ⚠ 전역 뿌리는 같은 원문이 딴 데서 다른 번역을 쓰면 부딪힌다.  그때는
#            아래 build_dialogue_trie 가 **빌드를 세운다** -- 조용히 틀리지 않는다.
#
#          쓰는 법은 tools/mark_page_root_lines.py 를 볼 것.  실패한 줄을
#          화면에서 확인한 뒤 그 줄에만 찍는다.
PAGE_MODES = ("PAGE",)
ROOT_MODES = CONTEXT_MODES + PAGE_MODES


def parse_context_pack(row: SourceRow) -> int:
    try:
        pack = int(row.pack.strip(), 16)
    except ValueError as exc:
        raise RuntimeError(
            f"root_mode={row.root_mode.strip().upper()} needs a captured hexadecimal pack: "
            f"{row.text_key}:{row.line_no} pack={row.pack!r}"
        ) from exc
    if not 0 <= pack <= 0xFF:
        raise RuntimeError(f"invalid context pack: {row.pack!r}")
    return pack


def build_dialogue_trie(
    rows: list[SourceRow],
    *,
    collapse_identical: bool = True,
) -> tuple[list[dict[bytes, Transition]], list[RuntimeRecord]]:
    groups: dict[str, list[SourceRow]] = defaultdict(list)
    order: list[str] = []
    for row in rows:
        if row.text_key not in groups:
            order.append(row.text_key)
        groups[row.text_key].append(row)

    # $0100-$01FF are deterministic MPR6 pack roots.  Reserve them up front so
    # ordinary child states and pack roots can never collide.  Speaker-specific
    # roots are allocated from $0200 upward and reached through an exact
    # pack-state speaker record.
    nodes: list[dict[bytes, Transition]] = [dict() for _ in range(CONTEXT_STATE_BASE)]
    context_speakers: dict[tuple[int, str], int] = {}

    def contextual_root(row: SourceRow) -> int:
        pack = parse_context_pack(row)
        # ★ PACK 은 화자를 일부러 안 본다.  화자 방은 게임이 그리는 일본어
        #   화자명을 거쳐야 도달하므로 `speaker` 열이 틀리면 번역이 안 뜬다.
        #   팩만으로 갈리는 줄은 그 위험을 질 이유가 없다.
        if row.root_mode.strip().upper() == "PACK" or not row.speaker.strip():
            return PACK_STATE_BASE | pack
        key = (pack, row.speaker.strip())
        state = context_speakers.get(key)
        if state is None:
            state = len(nodes)
            if state >= WILDCARD_STATE:
                raise RuntimeError("context state space exhausted")
            nodes.append({})
            context_speakers[key] = state
        return state

    _trie_conflicts: list[tuple[str, str, str, str, str]] = []
    for text_key in order:
        state = 0
        page = None
        for row in sorted(groups[text_key], key=lambda item: item.line_no):
            # 페이지는 **line_no 로** 센다.  남은 행 개수로 세면 안 된다 --
            # 화자명 줄처럼 빌드에서 빠진 행이 있으면 경계가 그만큼 밀린다
            # (2026-08-19: R01170 의 :3 화자명을 지웠더니 :4 가 3 번째로 밀려
            # 사슬 안에 남았다).  게임은 화자명도 한 줄로 세므로 원래 번호가
            # 맞다 -- 로그의 record_line 이 화자명 줄에도 번호를 준다.
            row_page = (row.line_no - 1) // PAGE_LINES
            if page is not None and row_page != page:
                state = 0
            page = row_page
            mode = row.root_mode.strip().upper()
            # ★ PAGE 는 페이지 격자가 못 잡는 자리를 손으로 재운다 (PAGE_MODES 주석).
            #   전역 뿌리에 **그대로 둔다** -- 팩 방으로 보내면 실기에서 못 찾는다.
            if mode in PAGE_MODES:
                state = 0
            elif state == 0 and mode in CONTEXT_MODES:
                state = contextual_root(row)
            source = encode_source_text(row.jp_text)
            if not source:
                raise RuntimeError(f"empty runtime source: {text_key}:{row.line_no}")
            transition = nodes[state].get(source)
            ref = f"{text_key}:{row.line_no}"
            if transition is None:
                transition = Transition(source=source, ko_text=row.ko_text, refs=[ref])
                nodes[state][source] = transition
            else:
                if transition.ko_text != row.ko_text:
                    if TRIE_REPORT:
                        _trie_conflicts.append(
                            (transition.refs[0], ref, transition.ko_text, row.ko_text,
                             row.jp_text))
                    else:
                        raise RuntimeError(
                            "same runtime trie state/source has conflicting Korean text: "
                            f"{transition.refs[0]} and {ref}"
                        )
                transition.refs.append(ref)

            # END and continuation occurrences can share the same source.  If
            # any occurrence continues, retain a child.  An actual END is
            # harmless: the next unrelated source misses this child and the
            # runtime retries from state zero.
            # 대사창은 화자명 + 본문 2 줄로 한 페이지다.  3 줄을 채우면 페이지가
            # 넘어가면서 **화자명이 다시 찍히고**, 화자 레코드는 WILDCARD/next=0
            # 이라 그 순간 state 가 0 으로 떨어진다.  그래서 4 번째 줄은 언제나
            # 루트에서 들어온다 -- 사슬을 계속 이으면 그 줄은 도달할 수 없는
            # state 에 등록되어 런타임이 영영 못 찾는다 (ROUTE_FAIL).
            #
            # 실측 (2026-08-19, 848 행 수집):
            #     line 1  루트 316 · 사슬  57
            #     line 2  루트   2 · 사슬 270
            #     line 3  루트   0 · 사슬  74
            #     line 4  루트   2 · 사슬   0      <- 여기서부터 전부 루트
            #
            # CONT 가 3 개 이어지면 그 자리를 END 처럼 끊고 다음 줄을 루트로
            # 보낸다.  소유자 판단 (2026-08-19): 게임이 3 줄까지만 한 페이지에
            # 담으므로 예외가 없다.
            if row.after_control != "END":
                if transition.child is None:
                    transition.child = len(nodes)
                    nodes.append({})
                state = transition.child
            else:
                state = 0

    if TRIE_REPORT and _trie_conflicts:
        print("", flush=True)
        print("=== trie 충돌 %d 건 ===" % len(_trie_conflicts), flush=True)
        print("  같은 (state, 원문) 자리에 서로 다른 한국어가 들어갔다.", flush=True)
        print("  고치는 법: 스튜디오에서 한쪽을 예외처리로 바꾼다"
              " (예외처리 행은 기본값에서 안 실린다).", flush=True)
        print("", flush=True)
        for first, second, ko1, ko2, jp in _trie_conflicts:
            print("  %14s  ko=%s" % (first, ko1[:38]), flush=True)
            print("  %14s  ko=%s" % (second, ko2[:38]), flush=True)
            print("  %14s  %s" % ("원문", jp[:38]), flush=True)
            print("", flush=True)
        raise RuntimeError("trie 충돌 %d 건 -- 위 목록 참고" % len(_trie_conflicts))

    records: list[RuntimeRecord] = []
    for state, node in enumerate(nodes):
        for source, transition in node.items():
            records.append(
                RuntimeRecord(
                    state=state,
                    next_state=transition.child or 0,
                    source=source,
                    ko_text=transition.ko_text,
                    kind="dialogue",
                    ref=",".join(transition.refs),
                )
            )
    # SRT3 can represent a state wildcard, so it may fold identical answers
    # here.  SRT4's one-read table has no wildcard-state branch: converting a
    # folded FFFF record to state 0000 would make a contextual `{EMPTY}` miss
    # and then fall through to an unrelated root translation with the same
    # Japanese bytes (R07734:2 / R10586:4 was the observed case).  Its caller
    # therefore asks for the complete, uncollapsed state table.
    if collapse_identical:
        records = collapse_identical_values(records)
    build_dialogue_trie.context_speakers = context_speakers
    return nodes, records


def collapse_identical_values(records: list[RuntimeRecord]) -> list[RuntimeRecord]:
    """값이 같은 레코드 무리를 와일드카드 하나로 접는다 (버킷 넘침 대책).

    왜
    --
    버킷은 원문의 10 비트 바이트합으로 정해지므로 **원문이 같으면 어떤 해시를
    써도 같은 칸**이다.  실측: 버킷 508 의 81 개 중 70 개가 원문 「す。」 하나이고
    그중 33 개는 번역이 전부 `{EMPTY}` 다 (2026-09-01).  BUCKET_COUNT 를 늘려도,
    해시에 길이를 섞어도 안 갈린다.

    그런데 그 33 개는 **값이 전부 같다.**  런타임이 보는 것은 (state, 원문) 이고
    답으로 돌려주는 것은 (next_state, asset) 뿐이므로, 값이 같은 무리는 어느
    state 에서 오든 같은 답을 준다 -- 와일드카드 한 줄로 접을 수 있다.

    규칙
    ----
    원문마다 (ko_text, next_state) 가 같은 무리 중 **가장 큰 것 하나**를 고른다.
    이미 진짜 와일드카드가 있는 원문은 건드리지 않는다 (한 원문에 와일드카드는
    하나뿐이어야 한다).  state 0 레코드는 **남긴다** -- 스캔 순서가
    `(state == WILDCARD, state, ...)` 라 state 0 이 언제나 먼저 잡히므로 공존해도
    답이 안 흔들린다.

    안전망
    ------
    이 함수가 틀리면 `build_lookup_sectors` 의 전수 검증이 잡는다.  거기서
    모든 (state, 원문) 을 실제 조회 경로로 다시 풀어보고 하나라도 어긋나면
    `runtime trie verification failed` 로 빌드를 세운다.  추측이 아니라 증명이다.

    끄려면 SNATCHER_NO_COLLAPSE=1.
    """

    if os.environ.get("SNATCHER_NO_COLLAPSE", "0") == "1":
        return records

    by_source: dict[bytes, list[RuntimeRecord]] = defaultdict(list)
    for record in records:
        by_source[record.source].append(record)

    drop: set[int] = set()
    add: list[RuntimeRecord] = []
    folded = 0
    for source, members in by_source.items():
        if any(item.state == WILDCARD_STATE for item in members):
            continue
        groups: dict[tuple[str, int], list[RuntimeRecord]] = defaultdict(list)
        for item in members:
            if item.state != 0:                 # state 0 은 그대로 둔다
                groups[(item.ko_text, item.next_state)].append(item)
        if not groups:
            continue
        best = max(groups.values(), key=len)
        if len(best) < 2:
            continue
        for item in best:
            drop.add(id(item))
        head = best[0]
        add.append(RuntimeRecord(
            state=WILDCARD_STATE,
            next_state=head.next_state,
            source=source,
            ko_text=head.ko_text,
            kind=head.kind,
            ref="collapsed:" + ",".join(item.ref.split(",")[0] for item in best[:4]),
        ))
        folded += len(best) - 1

    if not folded:
        return records
    kept = [item for item in records if id(item) not in drop]
    print(f"\n값이 같은 레코드를 접었다 -- {folded} 개 줄임 "
          f"(원문 {len(add)} 종 · {len(records)} -> {len(kept) + len(add)})", flush=True)
    return kept + add


def build_context_speaker_records(
    speakers: Path,
    context_speakers: dict[tuple[int, str], int],
) -> list[RuntimeRecord]:
    """Route a rendered speaker name from its pack root to pack+speaker root."""

    _, rows = read_dict_rows(speakers)
    by_korean = {
        row.get("ko_name", "").strip(): row
        for row in rows
        if row.get("ko_name", "").strip() and row.get("status", "") != "skip"
    }
    records: list[RuntimeRecord] = []
    for (pack, speaker), next_state in sorted(context_speakers.items()):
        row = by_korean.get(speaker)
        if row is None:
            raise RuntimeError(
                "root_mode=AUTO speaker is absent from "
                f"speaker_name_standard.tsv: {speaker!r}\n"
                "    (화자 라벨이 의심스러우면 root_mode=PACK 으로 두면 화자를 안 본다)"
            )
        records.append(RuntimeRecord(
            state=PACK_STATE_BASE | pack,
            next_state=next_state,
            source=row["jp_name"].encode("cp932"),
            ko_text=row["ko_name"],
            kind="context-speaker",
            ref=f"context-speaker:{pack:02X}:{speaker}",
        ))
    return records


def load_static_records(
    speakers: Path,
    ui_text: Path,
    *,
    include_ui: bool = True,
) -> list[RuntimeRecord]:
    records: dict[bytes, RuntimeRecord] = {}

    _, speaker_rows = read_dict_rows(speakers)
    for row in speaker_rows:
        ko = row.get("ko_name", "")
        if not ko or row.get("status", "") == "skip":
            continue
        source = row["jp_name"].encode("cp932")
        candidate = RuntimeRecord(
            state=WILDCARD_STATE,
            next_state=0,
            source=source,
            ko_text=ko,
            kind="speaker",
            ref=f"speaker:{row['speaker_id']}",
        )
        previous = records.get(source)
        if previous is not None and previous.ko_text != ko:
            raise RuntimeError(f"speaker/UI source conflict: {previous.ref} and {candidate.ref}")
        if previous is None:
            records[source] = candidate
        else:
            records[source] = RuntimeRecord(
                state=previous.state,
                next_state=previous.next_state,
                source=previous.source,
                ko_text=previous.ko_text,
                kind=previous.kind,
                ref=f"{previous.ref},{candidate.ref}",
            )

    # UI runs through a high-frequency renderer path.  It is intentionally
    # optional so production dialogue builds can leave every menu byte native
    # while the static-atlas work remains experimental.
    if not include_ui:
        return list(records.values())

    ui_header, ui_rows = read_dict_rows(ui_text)
    review = ui_review_column(ui_header)
    for row in ui_rows:
        ko = row.get("ko_text", "")
        if not ko or row.get("status", "") == "skip":
            continue
        if not is_ui_reviewed(row, review):
            continue
        source = row["jp_text"].encode("cp932")
        candidate = RuntimeRecord(
            state=WILDCARD_STATE,
            next_state=0,
            source=source,
            ko_text=ko,
            kind="ui",
            ref=f"ui:{row['ui_id']}",
        )
        previous = records.get(source)
        if previous is not None and previous.ko_text != ko:
            raise RuntimeError(f"speaker/UI source conflict: {previous.ref} and {candidate.ref}")
        if previous is None:
            records[source] = candidate
        else:
            records[source] = RuntimeRecord(
                state=previous.state,
                next_state=previous.next_state,
                source=previous.source,
                ko_text=previous.ko_text,
                kind=previous.kind,
                ref=f"{previous.ref},{candidate.ref}",
            )
    return list(records.values())


def expected_static_references(
    speakers: Path,
    ui_text: Path,
    *,
    include_ui: bool = True,
) -> set[str]:
    """Return every enabled translator row that must reach the runtime table."""

    expected: set[str] = set()
    _, speaker_rows = read_dict_rows(speakers)
    for row in speaker_rows:
        if row.get("ko_name", "") and row.get("status", "") != "skip":
            expected.add(f"speaker:{row['speaker_id']}")

    if not include_ui:
        return expected

    ui_header, ui_rows = read_dict_rows(ui_text)
    review = ui_review_column(ui_header)
    for row in ui_rows:
        if not row.get("ko_text", "") or row.get("status", "") == "skip":
            continue
        if is_ui_reviewed(row, review):
            expected.add(f"ui:{row['ui_id']}")
    return expected


def verify_static_reference_coverage(
    speakers: Path,
    ui_text: Path,
    static_records: list[RuntimeRecord],
    *,
    include_ui: bool = True,
) -> tuple[int, int]:
    """Fail the build if a reviewed speaker/UI row disappeared during dedupe."""

    expected = expected_static_references(speakers, ui_text, include_ui=include_ui)
    emitted = {
        ref
        for record in static_records
        for ref in record.ref.split(",")
        if ref.startswith(("speaker:", "ui:"))
    }
    missing = sorted(expected - emitted)
    extra = sorted(emitted - expected)
    if missing or extra:
        raise RuntimeError(
            "speaker/UI runtime coverage mismatch: "
            f"missing={missing[:10]} extra={extra[:10]}"
        )
    speaker_count = sum(ref.startswith("speaker:") for ref in emitted)
    ui_count = sum(ref.startswith("ui:") for ref in emitted)
    return speaker_count, ui_count


def period_glyph() -> bytes:
    # Keep the parser-safe F040 two-byte code, but draw its 2x2 dot near the
    # left side of the cell.  The old x=10 placement looked like a full extra
    # space after Korean text; x=4 keeps a natural punctuation gap.
    return bytes(24) + bytes((0x0C, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x00, 0x00))


def ellipsis_glyph() -> bytes:
    """Three compact dots, one row above the baseline and left-biased (F042)."""

    # The previous 0x63/0x18 pattern sat on the last two scanlines.  Beside a
    # following Hangul character it could read as an orphan dot below that
    # character.  Move it one pixel left and one scanline up.
    return bytes(22) + bytes((0xC6, 0x30, 0xC6, 0x30)) + bytes(6)


def build_assets(records: list[RuntimeRecord]) -> tuple[list[bytes], dict[str, int], list[dict[str, str]]]:
    distinct_text = sorted({record.ko_text for record in records})
    all_glyphs = ordered_hangul(distinct_text)
    found = parse_bdf(FONT_BDF, {ord(char) for char in all_glyphs})
    missing = [char for char in all_glyphs if ord(char) not in found]
    if missing:
        raise RuntimeError(f"missing Galmuri11 glyphs: {missing}")

    assets: list[bytes] = []
    text_to_asset: dict[str, int] = {}
    rows: list[dict[str, str]] = []
    for text in distinct_text:
        # BIOS 판에서는 한글이 시스템 카드 글리프로 나간다.  줄마다 글리프를
        # 모을 이유도, 15 칸에 맞출 이유도 없다.
        glyphs = () if BIOS_HANGUL else ordered_hangul([text])
        if len(glyphs) > FONT_GLYPH_CAPACITY - 4:
            raise RuntimeError(
                f"line needs {len(glyphs)} Hangul glyphs (>{FONT_GLYPH_CAPACITY - 4}): {text!r}"
            )
        custom = {char: bytes(HANGUL_CODES[index]) for index, char in enumerate(glyphs)}
        encoded = encode_game_text(text, custom)
        expected_fe = [int(match.group(1)) for match in FE_TOKEN_RE.finditer(text)]
        actual_fe = [encoded[index + 1] for index, value in enumerate(encoded[:-1]) if value == 0xFE]
        if actual_fe != expected_fe:
            raise RuntimeError(
                "FE markup was emitted as printable text or changed order: "
                f"expected={expected_fe} actual={actual_fe} text={text!r}"
            )
        if len(encoded) > ASSET_TEXT_CAPACITY:
            raise RuntimeError(
                f"encoded line needs {len(encoded)} bytes (>{ASSET_TEXT_CAPACITY}): {text!r}"
            )

        font = bytearray(period_glyph() + bytes(32) + ellipsis_glyph())
        for char in glyphs:
            font.extend(glyph_1bpp_left_shifted(*found[ord(char)]))
        font.extend(bytes(FONT_BYTES - len(font)))
        if len(font) != FONT_BYTES:
            raise RuntimeError("bad per-line font size")
        helper_offset = FRACTIONAL_SPACE_HELPER_INDEX * 32
        font[helper_offset:helper_offset + 32] = FRACTIONAL_SPACE_HELPER

        payload = bytearray(track24.USER_DATA_SIZE)
        payload[0:4] = b"AST2"
        payload[4] = len(encoded)
        payload[5] = len(glyphs)
        payload[6:8] = len(font).to_bytes(2, "little")
        payload[ASSET_HEADER_SIZE:ASSET_HEADER_SIZE + len(encoded)] = encoded
        payload[ASSET_FONT_OFFSET:ASSET_FONT_OFFSET + len(font)] = font
        asset_index = len(assets)
        assets.append(bytes(payload))
        text_to_asset[text] = asset_index
        rows.append(
            {
                "asset_index": str(asset_index),
                "encoded_bytes": str(len(encoded)),
                "hangul_glyphs": str(len(glyphs)),
                "encoded_hex": encoded.hex(" ").upper(),
                "ko_text": text,
                "payload_sha256": sha256(bytes(payload)),
            }
        )
    return assets, text_to_asset, rows


def build_buckets(
    records: list[RuntimeRecord],
    text_to_asset: dict[str, int],
    *,
    ship_buckets: bool = True,
) -> tuple[list[bytes], list[dict[str, str]], int]:
    """`ship_buckets=False` 면 704 B 한도로 빌드를 죽이지 않는다.

    SRT4 는 이 버킷을 **안 쓴다**.  `lookup_records.tsv` 만 받아 16K 슬롯표로
    다시 담고, 런타임은 슬롯 하나(704 B)를 읽는다 -- 버킷을 워킹램에 올려
    훑는 것은 SRT3 의 방식이다 (`build_direct_overlay_layout` 머리말 참고).
    그런데 그 SRT3 한도가 SRT4 빌드까지 죽이고 있었다: 디스크에 안 실릴
    버킷이 꽉 찼다는 이유로 멈춘다.

    버킷 자체는 계속 만든다 -- `verify_runtime_lookup` 이 "모든 레코드가
    trie 로 도달 가능한가" 를 이걸로 검사한다.  그 검사는 살린다.
    """
    grouped: dict[int, list[RuntimeRecord]] = defaultdict(list)
    for record in records:
        grouped[hash10(record.source)].append(record)

    # State zero and wildcard records are both eligible during the root pass.
    # Reject any signature that could therefore select two different results.
    signatures: dict[tuple[int, int, int, int, int], RuntimeRecord] = {}
    for record in records:
        length, xor_value, cumulative = source_fingerprint(record.source)
        # 2026-09-01: state 0 과 와일드카드를 **한 칸으로 보던 것**을 갈랐다.
        #
        #   근거는 스캔 순서다.  버킷 안에서 레코드는
        #   `(state == WILDCARD_STATE, state, ...)` 로 정렬되므로 와일드카드는
        #   언제나 맨 뒤다.  state 0 에서 조회하면 state 0 레코드가 **먼저** 잡히고
        #   와일드카드까지 가지 않는다.  둘이 공존해도 답이 안 흔들린다.
        #
        #   이 보수적 가드 때문에 `collapse_identical_values` 가 버킷 508 의
        #   「す。」 33 개를 접지 못했다 (그 원문에 state 0 레코드가 하나 있다).
        #   틀리면 아래 `build_lookup_sectors` 의 전수 검증이 잡는다.
        applicable_state = record.state
        key = (hash10(record.source), applicable_state, length, xor_value, cumulative)
        previous = signatures.get(key)
        if previous is not None and (
            previous.next_state != record.next_state or previous.ko_text != record.ko_text
        ):
            raise RuntimeError(
                "ambiguous runtime fingerprint: "
                f"{previous.ref} and {record.ref}"
            )
        signatures.setdefault(key, record)

    sectors: list[bytes] = []
    rows: list[dict[str, str]] = []
    maximum = 0
    over_cap: list[tuple[int, int, int]] = []
    _bucket_usage: list[tuple[int, int, int]] = []
    for bucket in range(BUCKET_COUNT):
        members = sorted(
            grouped.get(bucket, []),
            key=lambda item: (item.state == WILDCARD_STATE, item.state, item.source, item.ref),
        )
        body = bytearray()
        for record in members:
            length, xor_value, cumulative = source_fingerprint(record.source)
            if length > 0xFF:
                raise RuntimeError(f"source exceeds 255 bytes: {record.ref}")
            asset = text_to_asset[record.ko_text]
            body.extend(record.state.to_bytes(2, "little"))
            body.extend(record.next_state.to_bytes(2, "little"))
            body.extend(asset.to_bytes(2, "little"))
            body.extend((length, xor_value, cumulative))
            rows.append(
                {
                    "bucket": str(bucket),
                    "state": f"{record.state:04X}",
                    "next_state": f"{record.next_state:04X}",
                    "asset_index": str(asset),
                    "kind": record.kind,
                    "source_length": str(length),
                    "source_xor": f"{xor_value:02X}",
                    "source_cumulative": f"{cumulative:02X}",
                    "source_hex": record.source.hex(" ").upper(),
                    "reference": record.ref,
                    "ko_text": record.ko_text,
                }
            )
        used = BUCKET_HEADER_SIZE + len(body)
        maximum = max(maximum, used)
        _bucket_usage.append((used, bucket, len(members)))
        if used > ASSET_READ_BYTES and not BUCKET_REPORT:
            if ship_buckets:
                raise RuntimeError(
                    f"lookup bucket {bucket} needs {used} bytes; cache limit is {ASSET_READ_BYTES}"
                )
            over_cap.append((bucket, used, len(members)))
        # 넘겨도 검증은 돌아야 하므로 섹터에는 들어가야 한다.  여기를 넘으면
        # verify_runtime_lookup 이 잘린 버킷을 읽어 엉뚱한 곳에서 죽는다.
        if used > track24.USER_DATA_SIZE:
            raise RuntimeError(
                f"lookup bucket {bucket} needs {used} bytes; sector is {track24.USER_DATA_SIZE}"
            )
        payload = bytearray(track24.USER_DATA_SIZE)
        payload[0:4] = b"SBK3"
        payload[4:6] = len(members).to_bytes(2, "little")
        payload[6:8] = used.to_bytes(2, "little")
        payload[8:8 + len(body)] = body
        sectors.append(bytes(payload))
    if BUCKET_REPORT:
        over = [u for u in _bucket_usage if u[0] > ASSET_READ_BYTES]
        _bucket_usage.sort(reverse=True)
        cap = (ASSET_READ_BYTES - BUCKET_HEADER_SIZE) // 9
        print("", flush=True)
        print("=== 버킷 사용량 (한도 %d B = 레코드 %d 개) ===" % (ASSET_READ_BYTES, cap), flush=True)
        print("  넘친 버킷 %d 개 / %d" % (len(over), BUCKET_COUNT), flush=True)
        print("  가장 찬 것 12 개:", flush=True)
        for used, bucket, n in _bucket_usage[:12]:
            mark = "  ★넘침" if used > ASSET_READ_BYTES else ""
            print("    버킷 %4d  %4d B  레코드 %3d%s" % (bucket, used, n, mark), flush=True)
        nonempty = [u for u in _bucket_usage if u[2] > 0]
        print("  쓰는 버킷 %d · 레코드 총 %d · 평균 %.1f" % (
            len(nonempty), sum(u[2] for u in _bucket_usage),
            sum(u[2] for u in _bucket_usage) / max(1, len(nonempty))), flush=True)
        for used, bucket, n in over:
            print("", flush=True)
            print("=== 넘친 버킷 %d 의 내용 (%d 개) ===" % (bucket, n), flush=True)
            for r in [x for x in rows if x["bucket"] == str(bucket)]:
                print("    state %s  len %3s  %-14s %s" % (
                    r["state"], r["source_length"], r["reference"][:14],
                    r["ko_text"][:30]), flush=True)
        if over and ship_buckets:
            raise RuntimeError("버킷 %d 개가 한도를 넘었다 -- 위 목록 참고" % len(over))
    if over_cap:
        print("", flush=True)
        print("  버킷 %d 개가 SRT3 한도(%d B)를 넘었다 -- SRT4 는 버킷을 안 쓰므로 넘어간다:"
              % (len(over_cap), ASSET_READ_BYTES), flush=True)
        for bucket, used, n in sorted(over_cap, key=lambda x: -x[1])[:8]:
            print("    버킷 %4d  %4d B  레코드 %3d" % (bucket, used, n), flush=True)
    return sectors, rows, maximum


def verify_runtime_lookup(
    nodes: list[dict[bytes, Transition]],
    static_records: list[RuntimeRecord],
    buckets: list[bytes],
    text_to_asset: dict[str, int],
) -> None:
    def lookup(state: int, source: bytes, *, wildcard: bool) -> tuple[int, int] | None:
        payload = buckets[hash10(source)]
        count = int.from_bytes(payload[4:6], "little")
        signature = source_fingerprint(source)
        cursor = BUCKET_HEADER_SIZE
        for _ in range(count):
            record_state = int.from_bytes(payload[cursor:cursor + 2], "little")
            next_state = int.from_bytes(payload[cursor + 2:cursor + 4], "little")
            asset = int.from_bytes(payload[cursor + 4:cursor + 6], "little")
            candidate_signature = tuple(payload[cursor + 6:cursor + 9])
            cursor += RECORD_SIZE
            if candidate_signature != signature:
                continue
            if record_state == state or (wildcard and record_state == WILDCARD_STATE):
                return next_state, asset
        return None

    for state, node in enumerate(nodes):
        for source, transition in node.items():
            found = lookup(state, source, wildcard=True)
            expected = (transition.child or 0, text_to_asset[transition.ko_text])
            if found != expected:
                raise RuntimeError(f"runtime trie verification failed at state {state}: {found} != {expected}")
    for record in static_records:
        lookup_state = 0 if record.state == WILDCARD_STATE else record.state
        found = lookup(lookup_state, record.source, wildcard=True)
        expected = (record.next_state, text_to_asset[record.ko_text])
        if found != expected:
            raise RuntimeError(f"runtime static verification failed: {record.ref}: {found} != {expected}")


def build(
    master: Path,
    speakers: Path,
    ui_text: Path,
    out_dir: Path,
    compiled_dir: Path,
    clean: bool,
    review_only: bool = False,
    include_ui: bool = True,
    ship_buckets: bool = True,
    collapse_identical: bool = True,
) -> dict:
    if clean and out_dir.exists():
        shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    # A review-only build is controlled by the explicit O/예외처리 column,
    # not by the draft workflow status.  Reviewers commonly leave a finished
    # runtime-import row as "todo" while marking it O; filtering by status
    # first silently omitted those rows from the patched lookup table.
    reviewed_source_rows = 0
    review_exception_rows = 0
    normalized_root_conflicts = 0
    normalized_sequence_conflicts = 0
    if review_only:
        selected, exceptions = reviewed_row_ids(master)
        rows = read_reviewed_source_rows(master, selected)
        reviewed_source_rows = len(rows)
        review_exception_rows = len(exceptions)
        # 예외처리 means "this fragment reads only after the row before it".
        # For a static record that predecessor is an earlier line_no of the same
        # text_key.  A runtime capture is keyed by its own bytes, so its head is
        # a *different* text_key sitting immediately before it in the file --
        # the same-key test can never pass for one, however correctly it is
        # marked.  Accept either shape.
        predecessors = getattr(reviewed_row_ids, "file_order_predecessor", {})
        reviewed_ids = {(row.text_key, row.line_no) for row in rows}
        for text_key, line_no in exceptions:
            if any(row.text_key == text_key and row.line_no < line_no for row in rows):
                continue
            if predecessors.get((text_key, line_no)) in reviewed_ids:
                continue
            raise RuntimeError(
                    f"context-only review row has no reviewed predecessor: {text_key}:{line_no}"
                )
        # A reviewed O with an actually blank translation intentionally keeps
        # the Japanese fallback.  Only visible translations (including the
        # explicit {EMPTY} token) become runtime records.
        rows, normalized_sequence_conflicts = normalize_identical_reviewed_sequences(
            rows, exceptions
        )
        rows, normalized_root_conflicts = normalize_reviewed_root_conflicts(rows)
    else:
        rows = read_rows(master, ALLOWED_STATUS)
    nodes, dialogue_records = build_dialogue_trie(
        rows, collapse_identical=collapse_identical
    )
    static_records = load_static_records(speakers, ui_text, include_ui=include_ui)
    static_records.extend(build_context_speaker_records(
        speakers,
        getattr(build_dialogue_trie, "context_speakers", {}),
    ))
    speaker_reference_count, ui_reference_count = verify_static_reference_coverage(
        speakers, ui_text, static_records, include_ui=include_ui
    )

    root = nodes[0]
    for record in static_records:
        transition = root.get(record.source)
        if transition is not None and transition.ko_text != record.ko_text:
            raise RuntimeError(
                f"root dialogue/static source conflict: {transition.refs[0]} and {record.ref}"
            )

    records = dialogue_records + static_records
    assets, text_to_asset, asset_rows = build_assets(records)
    buckets, lookup_rows, max_bucket_bytes = build_buckets(
        records, text_to_asset, ship_buckets=ship_buckets)
    verify_runtime_lookup(nodes, static_records, buckets, text_to_asset)

    lookup_user = b"".join(buckets)
    asset_user = b"".join(assets)
    (out_dir / "asset_user_sectors.bin").write_bytes(asset_user)
    # 버킷 섹터는 SRT3 디스크에만 실린다.  SRT4 는 lookup_records.tsv 만 받아
    # 16K 슬롯표로 다시 담으므로 이 2 MB 는 쓰이지 않고 버려졌다 (1024 x 2048).
    if ship_buckets:
        (out_dir / "lookup_user_sectors.bin").write_bytes(lookup_user)
        (out_dir / "track24_overlay_user.bin").write_bytes(lookup_user + asset_user)
    write_tsv(out_dir / "lookup_records.tsv", lookup_rows)
    write_tsv(out_dir / "assets.tsv", asset_rows)

    manifest = {
        "format": "SRT3",
        "description": "1024 verified source-fingerprint trie buckets plus one per-line text/font asset sector",
        "translation_master": str(master),
        "translation_master_sha256": sha256(master.read_bytes()),
        "translation_policy": (
            ("first unnamed review column is O, plus context-only 예외처리 rows"
             if REVIEW_EXCEPTIONS else
             "first unnamed review column is O (예외처리 ships nothing)")
            if review_only else "all translated draft/review/final rows"
        ),
        "review_exceptions_ship": REVIEW_EXCEPTIONS,
        "review_only": review_only,
        "reviewed_source_rows": reviewed_source_rows,
        "review_exception_rows": review_exception_rows,
        "review_marked_rows": len(selected) if review_only else 0,
        "normalized_root_conflicts": normalized_root_conflicts,
        "normalized_sequence_conflicts": normalized_sequence_conflicts,
        "speaker_name_standard": str(speakers),
        "speaker_name_standard_sha256": sha256(speakers.read_bytes()),
        "ui_text": str(ui_text),
        "ui_text_sha256": sha256(ui_text.read_bytes()),
        "ui_enabled": include_ui,
        "compiled_assets": str(compiled_dir),
        "bucket_hash": "unsigned byte sum modulo 1024",
        "bucket_count": BUCKET_COUNT,
        "bucket_header_bytes": BUCKET_HEADER_SIZE,
        "record_bytes": RECORD_SIZE,
        "maximum_bucket_bytes": max_bucket_bytes,
        "cache_read_limit": ASSET_READ_BYTES,
        "dialogue_trie_states": len(nodes),
        "dialogue_records": len(dialogue_records),
        "static_records": len(static_records),
        "speaker_references": speaker_reference_count,
        "ui_references": ui_reference_count,
        "record_count": len(records),
        "asset_count": len(assets),
        "asset_header_bytes": ASSET_HEADER_SIZE,
        "asset_text_offset": ASSET_HEADER_SIZE,
        "asset_text_capacity": ASSET_TEXT_CAPACITY,
        "asset_font_offset": ASSET_FONT_OFFSET,
        "asset_read_bytes": ASSET_READ_BYTES,
        "font_bytes": FONT_BYTES,
        "track24_added_sectors": BUCKET_COUNT + len(assets),
        "track24_added_raw_bytes": (BUCKET_COUNT + len(assets)) * track24.RAW_SECTOR_SIZE,
        # SRT4 빌드는 버킷 섹터를 안 쓴다 (ship_buckets=False).  아래 크기/해시는
        # "SRT3 로 실었다면" 의 감사 기록이지 실제 파일이 아니다 -- 안 쓴 파일을
        # 매니페스트가 2 MB 로 적어 두면 다음 사람이 찾다가 헛짚는다.
        "buckets_shipped": ship_buckets,
        "files": {
            "lookup_user_sectors.bin": {
                "written": ship_buckets,
                "bytes": len(lookup_user),
                "sha256": sha256(lookup_user),
            },
            "asset_user_sectors.bin": {
                "bytes": len(asset_user),
                "sha256": sha256(asset_user),
            },
        },
    }
    (out_dir / "runtime_layout.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--master", type=Path, default=DEFAULT_MASTER)
    parser.add_argument("--speaker-file", type=Path, default=DEFAULT_SPEAKERS)
    parser.add_argument("--ui-file", type=Path, default=DEFAULT_UI)
    parser.add_argument("--compiled-dir", type=Path, default=DEFAULT_COMPILED)
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--clean", action="store_true")
    parser.add_argument("--review-only", action="store_true")
    parser.add_argument("--no-ui", action="store_true", help="leave all UI/menu text native")
    args = parser.parse_args()
    manifest = build(
        args.master,
        args.speaker_file,
        args.ui_file,
        args.out_dir,
        args.compiled_dir,
        args.clean,
        args.review_only,
        not args.no_ui,
    )
    print(
        "runtime layout: "
        f"records={manifest['record_count']} assets={manifest['asset_count']} "
        f"states={manifest['dialogue_trie_states']} "
        f"max_bucket={manifest['maximum_bucket_bytes']} "
        f"raw_added={manifest['track24_added_raw_bytes']}"
    )


if __name__ == "__main__":
    main()
