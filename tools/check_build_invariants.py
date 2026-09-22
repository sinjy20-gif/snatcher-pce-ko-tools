#!/usr/bin/env python3
"""구운 판이 **되풀이해서 물린 함정들**에 걸리지 않았는지 기계로 검사한다.

왜
--
지금까지 우리를 문 것들은 전부 "사람이 기억해야 하는 규칙" 이었다.

    팩만 굽고 mini index 를 안 돌림      -> 자막이 조용히 안 뜬다
    rom-resident 인데 스케줄러를 또 심음  -> 빌더 [3/3] 안내가 낡았다
    마스터 표 3 종이 따로 놂             -> 2026-09-08 voice_console_keys 만 안 자랐다
    Track02 -> BIOS 훅                  -> MPR7 에 원본 뱅크가 얹혀 폭주 (GFX r1~r4)
    렌더러/디스패처가 한도를 넘음         -> 조용히 깨진다
    CUE 가 가리키는 트랙이 없음           -> 2026-09-09 r5 가 그 상태로 왔다
    BIOS 굴이 실제로는 안 비었음          -> $ECF9 꼬리 386 B 전례

전부 기계로 확인할 수 있는 것들이다.  이 도구가 대신 기억한다.

    python tools/check_build_invariants.py 0.6.5
    python tools/check_build_invariants.py            가장 최근 판
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import re
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = Path(r"C:\snatcher")
PATCH = ROOT / "build" / "patch"
SUBS = ROOT / "build" / "cutscene_subs"
TRANS = ROOT / "snatcher_tool" / "translation"
FW = ROOT / "Mesen_2.2.1_Windows" / "Firmware"
ORIGINAL = FW / "[BIOS] Super CD-ROM System (Japan) (v3.0).pce.JP_ORIGINAL"
TRACK02_NAME = "Snatcher CD-ROMantic (Japan) (Track 02) [KO].bin"
TRACK02_BASELINES = [
    ("현재 대사 기준판", PATCH / "0.4.6.61-dictionary-key-vram" / TRACK02_NAME),
    ("0.6.2", PATCH / "0.6.2" / TRACK02_NAME),
]

RENDERER_SAFE = 671          # 엔진 한도.  ⚠672 가 아니라 671 이다
DISPATCHER_SAFE = 2957
# 2026-09-08 `0.5.192` 로 도달 불가 실측.  `direct_return_patch` 가 $FEC9 에 RTS 를 박았다
DEAD_REGION = (0xFECB, 0xFEF9, "옛 지문 검사 블록 (legacy_fec7_fallthrough=false)")

BANK = 0x2000

# 2026-09-05 기준 **의도한** 원본 덮어쓰기.  여기 없는 자리가 새로 생기면 경고한다.
#   뱅크0  점프표 $E009(CD_READ) 항목 · $F5F5·$F687(AD_CPLAY) 훅
#   뱅크1  한글 글꼴 슬롯표 데이터 (코드가 아니다)
EXPECTED_OVERWRITE = [
    (0, 0xE00A, 0xE00B), (0, 0xF5F5, 0xF5F7), (0, 0xF687, 0xF689),
    (1, 0xE97D, 0xEA81),
]

results: list[tuple[str, str, str]] = []


def track(folder: Path, number: str) -> Path | None:
    """`[KO]` 는 glob 에서 문자 클래스로 먹힌다.  이름으로 직접 고른다."""
    tag = f"(Track {number}) [KO].bin"
    for f in folder.iterdir():
        if f.is_file() and f.name.endswith(tag):
            return f
    return None


def ok(name: str, detail: str = "") -> None:
    results.append(("OK", name, detail))


def bad(name: str, detail: str) -> None:
    results.append(("★", name, detail))


def warn(name: str, detail: str) -> None:
    results.append(("!", name, detail))


def sha(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as fh:
        for c in iter(lambda: fh.read(1 << 22), b""):
            h.update(c)
    return h.hexdigest().upper()


def newest_build() -> Path:
    cands = [d for d in PATCH.iterdir()
             if d.is_dir() and list(d.glob("Syscard3_galmuri_*.pce"))]
    if not cands:
        sys.exit("구운 판이 없다")
    return max(cands, key=lambda d: d.stat().st_mtime)


# ---------------------------------------------------------------- 검사들

def check_cue(folder: Path) -> None:
    cue = next(folder.glob("*.cue"), None)
    if cue is None:
        bad("CUE", "CUE 파일이 없다")
        return
    want = re.findall(r'FILE "([^"]+)"', cue.read_text(encoding="utf-8", errors="replace"))
    missing = [w for w in want if not (folder / w).is_file()]
    zero = [w for w in want if (folder / w).is_file() and (folder / w).stat().st_size == 0]
    if missing or zero:
        bad("CUE 완결", f"트랙 {len(want)} 중 없음 {len(missing)} · 0 바이트 {len(zero)}"
                        + (f" -- 첫 누락 {missing[0]}" if missing else ""))
    else:
        total = sum((folder / w).stat().st_size for w in want)
        ok("CUE 완결", f"트랙 {len(want)} · {total / 1e6:,.0f} MB")


def check_pack_tag(folder: Path, man: dict) -> None:
    pack = SUBS / "subtitle_pack.bin"
    if not pack.is_file():
        warn("팩 태그", "subtitle_pack.bin 이 없다")
        return
    live = sha(pack)[:16]
    recorded = str(man.get("frozen_pack_sha256", ""))[:16]
    if not recorded:
        warn("팩 태그", "매니페스트에 frozen_pack_sha256 이 없다")
    elif live == recorded:
        ok("팩 태그", f"{live[:8]} -- 판과 팩이 짝이 맞는다")
    else:
        bad("팩 태그", f"판 {recorded[:8]} != 현재 팩 {live[:8]}"
                       "  -> 팩을 다시 굽고 판은 안 다시 구웠다")


def check_mini_index() -> None:
    pack = SUBS / "subtitle_pack.bin"
    mini = SUBS / "cdda_mini_index_all.bin"
    if not (pack.is_file() and mini.is_file()):
        warn("mini index", "파일이 없다")
        return
    if mini.stat().st_mtime + 1 < pack.stat().st_mtime:
        bad("mini index", "팩보다 낡았다 -> rec_off 가 어긋난다."
                          "  build_cdda_mini_index_all.py --write 를 돌릴 것")
    else:
        ok("mini index", f"{mini.stat().st_size:,} B · 팩보다 새것")


def check_track_hashes(folder: Path, man: dict) -> None:
    """매니페스트는 **빌더 시점** 값이다.

    `patch_track24_subtitle_pack.py` 가 그 뒤에 Track 24 를 다시 구우면서
    `.pre_pack_patch` 사본을 남긴다.  그래서 Track 24 는 **패치 전 사본**과
    대조해야 사슬이 맞는지 알 수 있다 -- 실물과 비교하면 늘 어긋난다.
    """
    for key, num in (("track24_sha256", "24"), ("track02_sha256", "02")):
        want = str(man.get(key, "")).upper()
        f = track(folder, num)
        if not want or f is None:
            continue
        pre = f.with_name(f.name + ".pre_pack_patch")
        if pre.is_file():
            got = sha(pre)
            label, note = f"track{num} 해시", " (패치 전 사본과 대조)"
        else:
            got = sha(f)
            label, note = f"track{num} 해시", ""
        if got == want:
            ok(label, got[:16] + note)
        else:
            bad(label, f"매니페스트 {want[:16]} != {got[:16]}{note}"
                       "  -> 판과 팩이 다른 세대다")


# Track 02 오버레이 **코드**가 사는 섹터 ($4000-$7FFF).  여기가 바뀌면 훅 위험이다.
OVERLAY_CODE_SECTORS = range(247, 255)
RAW_SECTOR = 2352


def check_track02_baseline(folder: Path, man: dict) -> None:
    """무엇이 바뀌었는지로 판정한다.

    막으려는 위험은 "Track02 -> BIOS 훅" 이지 **데이터 변경이 아니다**.
    route C 는 그래픽 블록을 제자리 치환하므로 데이터는 정당하게 바뀐다.
    """
    f = track(folder, "02")
    if f is None:
        warn("Track02 기준", "Track 02 파일이 없다")
        return

    # all_in_one 체인은 대사 기준판을 최신 마스터로 다시 굽는다. 고정된 0.6.2와
    # 비교하면 그 정상 변경(섹터 250/254)을 훅 오염으로 오인한다. 빌드 자체가
    # 기록한 기준 해시와 맞는 기준판을 우선 고른다. 옛 판 감사도 계속 되도록
    # 0.6.2를 후순위 후보로 남긴다.
    audit_sha = str(
        man.get("overlay_static_audit", {}).get("track02_sha256", "")
    ).upper()
    candidates = [(label, path) for label, path in TRACK02_BASELINES if path.is_file()]
    if audit_sha:
        matched = [(label, path) for label, path in candidates if sha(path) == audit_sha]
        if matched:
            baseline_label, baseline = matched[0]
        elif sha(f) == audit_sha:
            ok("Track02 기준", "매니페스트 기준 해시와 동일 -- Track02->BIOS 훅 없음")
            return
        else:
            warn("Track02 기준", "매니페스트가 가리키는 기준판 실물을 못 찾았다")
            return
    elif candidates:
        baseline_label, baseline = candidates[-1]
    else:
        warn("Track02 기준", "대조할 파일이 없다")
        return
    if sha(f) == sha(baseline):
        ok("Track02 기준", f"{baseline_label}과 바이트 동일 -- Track02->BIOS 훅 없음")
        return

    a, b = baseline.read_bytes(), f.read_bytes()
    changed = sorted({i // RAW_SECTOR for i in range(min(len(a), len(b))) if a[i] != b[i]})
    code_hit = [s for s in changed if s in OVERLAY_CODE_SECTORS]
    declared = set(man.get("route_c", {}).get("sectors_touched", []))
    undeclared = [s for s in changed if s not in declared]

    if code_hit:
        bad("Track02 기준",
            f"★오버레이 코드 섹터가 바뀌었다 {code_hit}"
            "  -- Track02->BIOS 훅이면 MPR7 에 원본 뱅크가 얹혀 폭주한다 (GFX r1~r4)")
    elif undeclared:
        bad("Track02 기준",
            f"선언 없이 바뀐 섹터 {undeclared}"
            "  -- 매니페스트 route_c.sectors_touched 에 적히지 않았다")
    else:
        ok("Track02 기준",
           f"선언된 데이터 블록만 바뀜 (섹터 {changed}) · 오버레이 코드 무손상")


# ★★★ 2026-09-22: 한글화 조각이 **조용히 빠지는 것**을 막는 그물.
#
#   실제로 두 번 당했다.
#     · 타이틀 메뉴·오프닝 자막이 0.7.26~0.7.28 실물에 아예 없었다
#     · 가우디 인물검색이 0.7.25 부터 빠져 있었다 (0.7.13~0.7.24 에는 있었다)
#   둘 다 **증상이 없다** -- 빌드도 감사도 통과하고 그 화면만 일본어로 남는다.
#   손으로 돌리던 단계라 한 번 빠뜨리면 그대로 굳는다.
#
#   그래서 산출물에서 **직접 지문을 읽어** 확인한다.  사슬을 믿지 않는다.
#   (이름, 파일, 논리오프셋 또는 raw오프셋, 있어야 할 바이트, 없을 때 뜻)
FEATURES = [
    ("가우디 검색 훅", "02", 0x0C6CD0, bytes.fromhex("2056BE"),
     "$B9E0 이 원본 그대로 -- apply_gaudi_to_build.py 가 안 돌았다"),
]

# 동굴이 0 이면 검색표가 안 실린 것이다.  **퀴즈 정답도 여기 산다** --
# 퀴즈는 디스크 문자열을 안 고치고 이 표가 한글 입력을 일본어로 되돌려 맞춘다.
# 그래서 동굴이 비면 인물검색과 퀴즈가 **같이** 죽는다.
CAVE_RAW, CAVE_CAP = 0x0C7146, 426
# 전체 표(이름 16 + 퀴즈 4, 314 B)의 머리 바이트.  실기로 확인된 0.7.24 와 동일.
CAVE_HEAD = bytes.fromhex("DAA9E38DE0BEA9BE8DE1BE")


def check_features(folder: Path) -> None:
    """조각마다 실물 바이트를 읽는다.  하나라도 없으면 **실패**다."""
    for name, track_no, off, want, why in FEATURES:
        f = track(folder, track_no)
        if f is None:
            warn(name, f"Track {track_no} 가 없어 확인 못 함")
            continue
        with open(f, "rb") as fh:
            fh.seek(off)
            got = fh.read(len(want))
        if got == want:
            ok(name, f"실렸다 (${off:07X} = {got.hex(' ').upper()})")
        else:
            bad(name, f"★빠졌다 -- ${off:07X} = {got.hex(' ').upper()}  {why}")

    f = track(folder, "02")
    if f is not None:
        with open(f, "rb") as fh:
            fh.seek(CAVE_RAW)
            cave = fh.read(CAVE_CAP)
        used = len([b for b in cave if b])
        if not any(cave):
            bad("가우디 검색표·퀴즈",
                f"★빠졌다 -- 동굴 ${CAVE_RAW:07X} 이 전부 0 · 인물검색과 퀴즈가 같이 죽는다")
        elif cave[:len(CAVE_HEAD)] != CAVE_HEAD:
            # ⚠ "0 이 아니면 통과" 로는 못 잡는다.  깁슨 하나짜리 옛 훅(97 B)도
            #   0 이 아니라서 통과했고, 자판은 한글인데 **검색이 0 건**이었다.
            bad("가우디 검색표·퀴즈",
                f"★옛 깁슨 훅만 실렸다 ({used} B) -- 이름 16 + 퀴즈 4 표가 아니다. "
                "apply_gaudi_search_full.py 가 안 돌았다")
        else:
            ok("가우디 검색표·퀴즈", f"이름 16 + 퀴즈 4 표가 실렸다 ({used} B)")

    # 부팅화면: 묶음이 비면 뒤쪽 메시지 표가 통째로 날아간다 (실기 확인)
    pce = next(folder.glob("Syscard3_galmuri_*.pce"), None)
    if pce is not None and pce.suffix == ".pce":
        rom = pce.read_bytes()
        d, i, sizes, start = rom[0x00297D:0x002B00], 0, [], 0
        while i < len(d) - 1:
            if d[i] == 0xFF and d[i + 1] == 0xFF:
                sizes.append(i - start)
                i += 2
                start = i
                continue
            i += 1
        head = sizes[:3]
        if len(head) < 3:
            bad("부팅화면 묶음", f"묶음을 셋 못 찾았다 {sizes[:6]}")
        elif 0 in head:
            bad("부팅화면 묶음",
                f"★빈 묶음이 있다 {head} -- PUSH RUN BUTTON 이 사라져 로딩이 안 된다")
        else:
            ok("부팅화면 묶음", f"{head} · 빈 묶음 없음")


def check_sizes(folder: Path, man: dict) -> None:
    d = man.get("native_dispatcher_bytes")
    if isinstance(d, int):
        (ok if d <= DISPATCHER_SAFE else bad)(
            "디스패처 크기", f"{d} / {DISPATCHER_SAFE} B"
            + ("" if d <= DISPATCHER_SAFE else "  ★한도 초과"))
    eng = sorted(SUBS.glob("engine_ac_lua_frame_rearm_*_6600.bin"),
                 key=lambda p: p.stat().st_mtime)
    if eng:
        n = eng[-1].stat().st_size
        (ok if n <= RENDERER_SAFE else bad)(
            "렌더러 크기", f"{n} / {RENDERER_SAFE} B ({eng[-1].name})"
            + ("" if n <= RENDERER_SAFE else "  ★한도 초과"))


def check_master_tables() -> None:
    tables = ["voice_events.tsv", "voice_keys.tsv", "voice_console_keys.tsv"]
    keysets: dict[str, set[str]] = {}
    for name in tables:
        p = TRANS / name
        if not p.is_file():
            warn("마스터 표", f"{name} 이 없다")
            return
        rows = list(csv.DictReader(
            io.StringIO(p.read_text(encoding="utf-8-sig", errors="replace")), delimiter="\t"))
        col = "event_id" if rows and "event_id" in rows[0] else "key"
        keysets[name] = {(r.get(col) or "").strip() for r in rows if (r.get(col) or "").strip()}
    sizes = {k: len(v) for k, v in keysets.items()}
    if len(set(sizes.values())) == 1:
        ok("마스터 표 3 종", f"키 {next(iter(sizes.values())):,} 개로 일치")
    else:
        base = keysets[tables[0]]
        detail = " · ".join(f"{k.split('.')[0]} {v}" for k, v in sizes.items())
        extra = []
        for name in tables[1:]:
            only = base - keysets[name]
            if only:
                extra.append(f"{name.split('.')[0]} 에 없는 키 {len(only)} (예: {sorted(only)[0]})")
        bad("마스터 표 3 종", detail + ("  -- " + " · ".join(extra) if extra else ""))


def check_bios_caves(folder: Path) -> None:
    bios = next(folder.glob("Syscard3_galmuri_*.pce"), None)
    if bios is None or not ORIGINAL.is_file():
        warn("BIOS 굴", "원본 BIOS 를 못 찾았다")
        return
    a, b = ORIGINAL.read_bytes(), bios.read_bytes()
    # 우리 코드가 사는 뱅크 0·1 만 본다 (뱅크 3 이상은 한글 글꼴 데이터다)
    def expected(i: int) -> bool:
        bank, cpu = i // BANK, i % BANK + 0xE000
        return any(bank == bk and lo <= cpu <= hi for bk, lo, hi in EXPECTED_OVERWRITE)

    guilty = [i for i in range(0, 2 * BANK)
              if a[i] != b[i] and a[i] not in (0x00, 0xFF) and not expected(i)]
    if not guilty:
        ok("BIOS 굴", "알려진 훅 말고 원본 코드를 덮은 자리 없음")
    else:
        spots = ", ".join(f"${i % BANK + 0xE000:04X}" for i in guilty[:8])
        bad("BIOS 굴", f"★목록에 없는 자리 {len(guilty)} B 를 덮었다: {spots}"
                       "  -- 의도한 훅이면 EXPECTED_OVERWRITE 에 추가할 것")


def check_dead_region(folder: Path) -> None:
    bios = next(folder.glob("Syscard3_galmuri_*.pce"), None)
    if bios is None:
        return
    b = bios.read_bytes()
    lo, hi, why = DEAD_REGION
    seg = b[lo - 0xE000:hi - 0xE000 + 1]
    live = sum(1 for x in seg if x != 0xFF)
    if live:
        warn("죽은 구간", f"${lo:04X}-${hi:04X} 에 아직 {live} B 가 들어 있다 ({why})"
                          "  -- 도달 불가라 무해하지만 굴을 막고 있다")
    else:
        ok("죽은 구간", f"${lo:04X}-${hi:04X} 비어 있음")


def check_final_bios(folder: Path, man: dict) -> None:
    bios = next(folder.glob("Syscard3_galmuri_*.pce"), None)
    if bios is None:
        bad("BIOS", "BIOS 파일이 없다")
        return
    if bios.stat().st_size != 262144:
        bad("BIOS 크기", f"{bios.stat().st_size} B (262,144 이어야 한다)")
        return
    final = sha(bios)
    recorded = str(man.get("bios_sha256", "")).upper()
    ok("BIOS", f"{final[:16]} · 262,144 B")
    if recorded and recorded != final:
        warn("매니페스트 BIOS 해시",
             f"{recorded[:16]} != 실물 {final[:16]}"
             "  -- 빌더 시점 값이라 cpu_cache/rom_resident 뒤에는 다른 것이 정상")
    copy = folder / "Syscard3.pce"
    if copy.is_file() and sha(copy) != final:
        bad("Syscard3.pce 사본", "named .pce 와 다르다 -- RetroArch 가 옛 판을 문다")
    elif copy.is_file():
        ok("Syscard3.pce 사본", "named .pce 와 동일")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("version", nargs="?")
    args = ap.parse_args()

    folder = PATCH / args.version if args.version else newest_build()
    if not folder.is_dir():
        sys.exit(f"판이 없다: {folder}")
    manp = folder / "manifest.json"
    man = json.loads(manp.read_text(encoding="utf-8")) if manp.is_file() else {}

    print("=" * 78)
    print(f"판  {folder.name}")
    print("=" * 78)

    check_final_bios(folder, man)
    check_cue(folder)
    check_track_hashes(folder, man)
    check_track02_baseline(folder, man)
    check_pack_tag(folder, man)
    check_mini_index()
    check_sizes(folder, man)
    check_master_tables()
    check_bios_caves(folder)
    check_dead_region(folder)
    check_features(folder)

    print()
    for mark, name, detail in results:
        print(f"  {mark:2} {name:20} {detail}")

    nbad = sum(1 for m, _, _ in results if m == "★")
    nwarn = sum(1 for m, _, _ in results if m == "!")
    print()
    print(f"  통과 {sum(1 for m, _, _ in results if m == 'OK')} · 경고 {nwarn} · ★실패 {nbad}")
    sys.exit(1 if nbad else 0)


if __name__ == "__main__":
    main()
