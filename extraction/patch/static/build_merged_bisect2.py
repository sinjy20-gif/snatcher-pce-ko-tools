"""merged-BODY 고장 원인 이분탐색 — 변수를 하나씩만 바꾼 빌드 3개.

배경
  merged-BODY (COMMON + 훅 2개 우회) 에서 대사창은 나오는데 글자가 안 보인다.
  $648C 훅이 0회라 렌더러가 그릴 글자가 없는 상태다.

  가설을 두 번 세웠고 두 번 틀렸다.
    "BODY 가 $5FF2 를 참조한다"  -> UI 0.1.67 로 반증 (읽기 0 / 실행 0)
    "bank6A 사본이 여러 개"      -> 0.2.26 diff 로 반증 ($66E5 는 한 곳뿐)

  더 추측하지 않고 변수를 하나씩 분리한다.

빌드 3개 (전부 KO 0.2.26 을 기준으로, 딱 한 가지만 바꾼다)

  1) bisect-common   COMMON 10바이트만 쓴다. 훅은 0.2.26 그대로
       $5FF2 4C 40 5E / $5FF5 4C 50 7F / $5FF8 A5 5A A5 5A
       -> 그 자리에 바이트를 쓰는 것 자체가 문제인지 본다
       -> 깨지면 $5FF2 배치가 원인 (UI 0.1.67 의 결론이 뒤집힌다)
       -> 정상이면 배치는 무죄. 우회가 원인이다

  2) bisect-render   COMMON + $66E5 만 우회. $648C 는 0.2.26 그대로 (JSR $7F50)
       -> 깨지면 렌더 훅 우회가 원인

  3) bisect-font     COMMON + $648C 만 우회. $66E5 는 0.2.26 그대로 (JSR $5E40)
       -> 깨지면 폰트 훅 우회가 원인

  1 정상 / 2 정상 / 3 정상 이면 두 우회의 조합이 문제이므로 merged-BODY 를
  다시 보되, 그때는 원인이 '조합' 으로 특정된다.

출력
  build/patch/MERGED BISECT/
    Track 02 [bisect-common].bin
    Track 02 [bisect-render].bin
    Track 02 [bisect-font].bin
    Track 01, 03~24  원본 복사 (공용)
    CUE 3개
"""
from __future__ import annotations

import hashlib
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_disc_patch import rebuild_mode1_sector  # noqa: E402

ROOT = Path(r"C:\snatcher")
ROM = ROOT / "rom(japan)" / "Snatcher CD-ROMantic (Japan)"
BODY_SRC = (ROOT / "build" / "patch" / "Snatcher_KO_0.2.26_STABLE_FULL"
            / "Snatcher CD-ROMantic (Japan) (Track 02) [KO 0.2.26].bin")
OUT = ROOT / "build" / "patch" / "MERGED BISECT2"

RAW, HDR, USER = 2352, 16, 2048
B68, B6A = 0x07B800, 0x07F800

COMMON_R, COMMON_F = 0x697F, 0x6982
CANARY_AT = 0x6985
CANARY = bytes((0xA5, 0x5A, 0xA5, 0x5A))
HOOK_R, HOOK_F = 0x66E5, 0x648C
BODY_RENDER_H, BODY_FONT_H = 0x5E40, 0x7F50


def cpu_to_user(cpu: int) -> int:
    if 0x4000 <= cpu <= 0x5FFF:
        return B68 + (cpu - 0x4000)
    if 0x6000 <= cpu <= 0x7FFF:
        return B6A + (cpu - 0x6000)
    raise ValueError(f"${cpu:04X}")


def u2raw(u: int) -> int:
    return (u // USER) * RAW + HDR + (u % USER)


def read_cpu(path: Path, cpu: int, n: int) -> bytes:
    out = bytearray()
    with path.open("rb") as f:
        for i in range(n):
            f.seek(u2raw(cpu_to_user(cpu + i)))
            out += f.read(1)
    return bytes(out)


def write_cpu(fh, cpu: int, data: bytes) -> set[int]:
    secs = set()
    for i, b in enumerate(data):
        u = cpu_to_user(cpu + i)
        secs.add(u // USER)
        fh.seek(u2raw(u))
        fh.write(bytes((b,)))
    return secs


def sha256(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        for c in iter(lambda: f.read(1 << 22), b""):
            h.update(c)
    return h.hexdigest().upper()


def make_cue(tag: str) -> None:
    src = (ROM / "Snatcher CD-ROMantic (Japan).cue").read_text(encoding="utf-8-sig")
    old = "Snatcher CD-ROMantic (Japan) (Track 02).bin"
    new = f"Snatcher CD-ROMantic (Japan) (Track 02) [{tag}].bin"
    (OUT / f"Snatcher CD-ROMantic (Japan) [{tag}].cue").write_text(
        src.replace(old, new), encoding="utf-8")


def build(name: str, redirect_render: bool, redirect_font: bool) -> None:
    print(f"\n[{name}]  렌더우회={redirect_render}  폰트우회={redirect_font}")
    dst = OUT / f"Snatcher CD-ROMantic (Japan) (Track 02) [{name}].bin"
    shutil.copyfile(BODY_SRC, dst)

    secs: set[int] = set()
    with dst.open("r+b") as fh:
        # COMMON 은 세 빌드 모두 동일하게 심는다
        secs |= write_cpu(fh, COMMON_R,
                          bytes((0x4C, BODY_RENDER_H & 0xFF, BODY_RENDER_H >> 8)))
        secs |= write_cpu(fh, COMMON_F,
                          bytes((0x4C, BODY_FONT_H & 0xFF, BODY_FONT_H >> 8)))
        secs |= write_cpu(fh, CANARY_AT, CANARY)
        if redirect_render:
            secs |= write_cpu(fh, HOOK_R + 1,
                              bytes((COMMON_R & 0xFF, COMMON_R >> 8)))
        if redirect_font:
            secs |= write_cpu(fh, HOOK_F + 1,
                              bytes((COMMON_F & 0xFF, COMMON_F >> 8)))
        for s in sorted(secs):
            fh.seek(s * RAW)
            sec = bytearray(fh.read(RAW))
            rebuild_mode1_sector(sec)
            fh.seek(s * RAW)
            fh.write(bytes(sec))

    r = read_cpu(dst, HOOK_R, 3)
    f = read_cpu(dst, HOOK_F, 3)
    c = read_cpu(dst, COMMON_R, 14)
    print(f"    $66E5 = {' '.join('%02X' % b for b in r)}"
          f"  = JSR ${r[1] | (r[2] << 8):04X}")
    print(f"    $648C = {' '.join('%02X' % b for b in f)}"
          f"  = JSR ${f[1] | (f[2] << 8):04X}")
    print(f"    COMMON= {' '.join('%02X' % b for b in c)}")
    print(f"    섹터 {sorted(secs)}   SHA-256 {sha256(dst)[:16]}...")
    make_cue(name)


def main() -> None:
    if not BODY_SRC.exists():
        raise SystemExit(f"0.2.26 원본 없음: {BODY_SRC}")
    OUT.mkdir(parents=True, exist_ok=True)

    base = read_cpu(BODY_SRC, COMMON_R, 14)
    print(f"0.2.26 의 $697F 부근 = {' '.join('%02X' % b for b in base)}")
    if set(base) != {0xFF}:
        print("  !! 경고: FF 가 아니다")

    build("b2-common", False, False)
    build("b2-both", True, True)

    print("\n[나머지 트랙 복사]")
    n = 0
    for p in sorted(ROM.glob("*.bin")):
        if "(Track 02)" in p.name:
            continue
        d = OUT / p.name
        if not d.exists():
            shutil.copyfile(p, d)
            n += 1
    print(f"    {n}개")

    (OUT / "TEST_IN_MESEN.txt").write_text(
        "merged-BODY 고장 원인 이분탐색\n"
        "\n"
        "세 빌드 모두 KO 0.2.26 기준이며, 딱 한 가지만 다르다.\n"
        "\n"
        "  bisect-common   COMMON 10바이트만 씀. 훅은 0.2.26 그대로\n"
        "                  $5FF2 4C 40 5E / $5FF5 4C 50 7F / $5FF8 A5 5A A5 5A\n"
        "                  $66E5 = JSR $5E40 (원래대로)\n"
        "                  $648C = JSR $7F50 (원래대로)\n"
        "\n"
        "  bisect-render   COMMON + $66E5 만 우회\n"
        "                  $66E5 = JSR $5FF2\n"
        "                  $648C = JSR $7F50 (원래대로)\n"
        "\n"
        "  bisect-font     COMMON + $648C 만 우회\n"
        "                  $66E5 = JSR $5E40 (원래대로)\n"
        "                  $648C = JSR $5FF5\n"
        "\n"
        "절차\n"
        "  각 CUE 를 로드 -> 파워 사이클 -> 첫 대사까지 진행\n"
        "  본문 한글이 KO 0.2.26 과 똑같이 나오는지만 본다.\n"
        "  UI 0.1.68 을 같이 돌리면 체인 횟수와 SP 도 볼 수 있다.\n"
        "\n"
        "판정\n"
        "  bisect-common 이 깨진다\n"
        "    -> $5FF2 에 바이트를 쓰는 것 자체가 원인이다.\n"
        "       (UI 0.1.67 의 '읽기 0' 결론이 뒤집힌다. 간접 접근이 있는 것)\n"
        "       COMMON 을 3순위 $697F-$69C1 로 옮긴다.\n"
        "\n"
        "  bisect-common 정상 + bisect-render 깨진다\n"
        "    -> 렌더 훅 우회가 원인.  JMP 로는 안 되는 규약이 있다.\n"
        "       프리로더가 반환 주소나 스택 깊이에 의존하는지 확인해야 한다.\n"
        "\n"
        "  bisect-common 정상 + bisect-font 깨진다\n"
        "    -> 폰트 훅 우회가 원인.  $7F50 이 JMP $69C2 로 끝나는 것과 관계된다.\n"
        "\n"
        "  셋 다 정상\n"
        "    -> 두 우회의 조합이 원인.  merged-BODY 를 다시 보되\n"
        "       그때는 원인이 '조합' 으로 특정된 상태다.\n"
        "\n"
        "참고: 지금까지 반증된 가설\n"
        "  BODY 가 $5FF2 를 참조한다     -> UI 0.1.67 읽기 0 / 실행 0\n"
        "  bank6A 사본이 여러 개다       -> 0.2.26 diff 결과 $66E5 는 한 곳뿐\n"
        "  스택 불균형                   -> SP 범위 $7C-$FF, 정상 최대 깊이 내\n"
        "  프리징                        -> $7610 은 정상 64회 대기 루프\n",
        encoding="utf-8")

    print(f"\n완료: {OUT}")


if __name__ == "__main__":
    main()
