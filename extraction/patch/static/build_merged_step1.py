"""오버레이 POC 1단계 — 고정 모드 병합 빌드 2개.

목적
  전환 코드를 넣지 않고, **COMMON 을 설치하고 훅을 그리로 우회시켜도 두 시스템이
  멀쩡한가** 만 검증한다.  변수를 하나만 바꾼다 (UI 0.5.7 검증과 같은 방식).

    merged-BODY   COMMON 설치 + 훅이 COMMON 경유 -> BODY 핸들러 고정
                  기대: KO 0.2.26 과 완전히 동일하게 동작
    merged-UI     COMMON 설치 + 훅이 COMMON 경유 -> UI 핸들러 고정
                  기대: UI 0.5.7 과 완전히 동일하게 동작

  둘 다 통과 = COMMON 설치와 훅 리다이렉트가 무해함이 증명된다.
  하나라도 깨짐 = 전환 코드를 만들기 전에 여기서 원인을 잡는다.

왜 이렇게 작은가
  모드가 빌드 시점에 고정이므로 판정 코드가 필요 없다.  COMMON 은 JMP 두 개뿐이다.
  그리고 원본 훅이 이미 `20 xx xx`(JSR) 이므로 **오퍼랜드 2바이트만** 바꾼다.

    $66E5  20 <lo> <hi>   ->  오퍼랜드를 $5FF2 로
    $648C  20 <lo> <hi>   ->  오퍼랜드를 $5FF5 로

COMMON 배치 ($5FF2-$5FFF, 14 B 실측 확정 구간)
    $5FF2  4C xx xx   JMP 렌더 핸들러   (BODY $5E40 / UI $5F30)
    $5FF5  4C xx xx   JMP 폰트 핸들러   (BODY $7F50 / UI $5CE7)
    $5FF8  A5 5A A5 5A  카나리아 4 B — 훼손 감시용
    $5FFC  00 00 00 00  여유

  JMP 이므로 핸들러의 RTS 가 원래 호출자에게 직접 돌아간다.  반환 규약이
  그대로 보존되고 COMMON 이 스택을 건드리지 않는다.

  훅 규약 차이도 자동으로 지켜진다.
    BODY : $66E5 3 B 만 교체된 상태이므로 $66E8 의 원본이 그대로 실행된다
    UI   : $66E5-$66EE 10 B 가 교체된 상태 (NOP x7) 이므로 UI 로더가 전부 처리한다
    COMMON 은 JMP 만 하므로 어느 쪽 규약도 바꾸지 않는다.

출력
  build/patch/MERGED STEP1/
    Track 02 [merged-BODY].bin
    Track 02 [merged-UI].bin
    Track 01, 03~24            원본 복사 (두 CUE 공용)
    CUE 2개
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
UI_SRC = (ROOT / "build" / "patch" / "UI 0.5.6+0.5.7"
          / "Snatcher CD-ROMantic (Japan) (Track 02) [UI 0.5.7].bin")
OUT = ROOT / "build" / "patch" / "MERGED STEP1"

RAW, HDR, USER = 2352, 16, 2048
BANK68_ISO, BANK6A_ISO = 0x07B800, 0x07F800

COMMON_RENDER = 0x5FF2      # JMP 렌더 핸들러
COMMON_FONT = 0x5FF5        # JMP 폰트 핸들러
CANARY_AT = 0x5FF8
CANARY = bytes((0xA5, 0x5A, 0xA5, 0x5A))

HOOK_RENDER = 0x66E5
HOOK_FONT = 0x648C

# 빌드별 (이름, 원본, 렌더 핸들러, 폰트 핸들러, 기대되는 기존 오퍼랜드)
VARIANTS = [
    ("merged-BODY", BODY_SRC, 0x5E40, 0x7F50, 0x5E40, 0x7F50),
    ("merged-UI",   UI_SRC,   0x5F30, 0x5CE7, 0x5F30, 0x5CE7),
]


def cpu_to_user(cpu: int) -> int:
    if 0x4000 <= cpu <= 0x5FFF:
        return BANK68_ISO + (cpu - 0x4000)
    if 0x6000 <= cpu <= 0x7FFF:
        return BANK6A_ISO + (cpu - 0x6000)
    raise ValueError(f"뱅크 밖 주소: ${cpu:04X}")


def user_to_raw(u: int) -> int:
    return (u // USER) * RAW + HDR + (u % USER)


def read_cpu(path: Path, cpu: int, n: int) -> bytes:
    out = bytearray()
    with path.open("rb") as f:
        for i in range(n):
            f.seek(user_to_raw(cpu_to_user(cpu + i)))
            out += f.read(1)
    return bytes(out)


def write_cpu(f, cpu: int, data: bytes) -> set[int]:
    """CPU 주소에 쓰고 영향받은 섹터 번호를 돌려준다."""
    sectors = set()
    for i, b in enumerate(data):
        u = cpu_to_user(cpu + i)
        sectors.add(u // USER)
        f.seek(user_to_raw(u))
        f.write(bytes((b,)))
    return sectors


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 22), b""):
            h.update(chunk)
    return h.hexdigest().upper()


def make_cue(tag: str) -> None:
    src_cue = ROM / "Snatcher CD-ROMantic (Japan).cue"
    text = src_cue.read_text(encoding="utf-8-sig")
    old = "Snatcher CD-ROMantic (Japan) (Track 02).bin"
    new = f"Snatcher CD-ROMantic (Japan) (Track 02) [{tag}].bin"
    if old not in text:
        raise SystemExit("원본 CUE 에서 Track 02 파일명을 찾지 못했다")
    (OUT / f"Snatcher CD-ROMantic (Japan) [{tag}].cue").write_text(
        text.replace(old, new), encoding="utf-8")


def build(name: str, src: Path, render_h: int, font_h: int,
          want_render: int, want_font: int) -> None:
    print(f"\n[{name}]")
    if not src.exists():
        raise SystemExit(f"원본 없음: {src}")

    # 1) 기존 훅이 기대한 모양인지 확인 — 다르면 즉시 중단
    r = read_cpu(src, HOOK_RENDER, 3)
    f_ = read_cpu(src, HOOK_FONT, 3)
    print(f"    $66E5 = {' '.join('%02X' % b for b in r)}")
    print(f"    $648C = {' '.join('%02X' % b for b in f_)}")
    if r[0] != 0x20 or (r[1] | (r[2] << 8)) != want_render:
        raise SystemExit(f"$66E5 가 JSR ${want_render:04X} 가 아니다. 중단")
    if f_[0] != 0x20 or (f_[1] | (f_[2] << 8)) != want_font:
        raise SystemExit(f"$648C 가 JSR ${want_font:04X} 가 아니다. 중단")

    # 2) COMMON 자리가 비어 있는지 확인 (원본은 FF 였다)
    cur = read_cpu(src, COMMON_RENDER, 14)
    print(f"    $5FF2-$5FFF = {' '.join('%02X' % b for b in cur)}")
    if set(cur) != {0xFF}:
        print("    !! 경고: COMMON 자리가 FF 가 아니다. 그래도 진행한다")

    dst = OUT / f"Snatcher CD-ROMantic (Japan) (Track 02) [{name}].bin"
    shutil.copyfile(src, dst)

    sectors: set[int] = set()
    with dst.open("r+b") as fh:
        # COMMON 본체
        sectors |= write_cpu(fh, COMMON_RENDER,
                             bytes((0x4C, render_h & 0xFF, render_h >> 8)))
        sectors |= write_cpu(fh, COMMON_FONT,
                             bytes((0x4C, font_h & 0xFF, font_h >> 8)))
        sectors |= write_cpu(fh, CANARY_AT, CANARY)
        # 훅 오퍼랜드만 교체 (opcode 20 은 그대로 둔다)
        sectors |= write_cpu(fh, HOOK_RENDER + 1,
                             bytes((COMMON_RENDER & 0xFF, COMMON_RENDER >> 8)))
        sectors |= write_cpu(fh, HOOK_FONT + 1,
                             bytes((COMMON_FONT & 0xFF, COMMON_FONT >> 8)))

        # 영향 섹터 EDC/ECC 재계산
        for s in sorted(sectors):
            fh.seek(s * RAW)
            sec = bytearray(fh.read(RAW))
            rebuild_mode1_sector(sec)
            fh.seek(s * RAW)
            fh.write(bytes(sec))
    print(f"    수정 섹터 {sorted(sectors)} (EDC/ECC 재계산 완료)")

    # 3) 결과 검증 — 읽어서 다시 확인
    r2 = read_cpu(dst, HOOK_RENDER, 3)
    f2 = read_cpu(dst, HOOK_FONT, 3)
    c2 = read_cpu(dst, COMMON_RENDER, 14)
    print(f"    검증 $66E5 = {' '.join('%02X' % b for b in r2)}"
          f"  = JSR ${r2[1] | (r2[2] << 8):04X}")
    print(f"    검증 $648C = {' '.join('%02X' % b for b in f2)}"
          f"  = JSR ${f2[1] | (f2[2] << 8):04X}")
    print(f"    검증 COMMON = {' '.join('%02X' % b for b in c2)}")
    assert r2[1] | (r2[2] << 8) == COMMON_RENDER
    assert f2[1] | (f2[2] << 8) == COMMON_FONT
    assert c2[0] == 0x4C and (c2[1] | (c2[2] << 8)) == render_h
    assert c2[3] == 0x4C and (c2[4] | (c2[5] << 8)) == font_h
    assert bytes(c2[6:10]) == CANARY
    print(f"    SHA-256 {sha256(dst)}")
    make_cue(name)


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for v in VARIANTS:
        build(*v)

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
        "오버레이 POC 1단계 — 고정 모드 병합 빌드\n"
        "\n"
        "무엇을 검증하는가\n"
        "  전환 코드는 들어 있지 않다.  COMMON 을 설치하고 훅을 그리로 우회시켜도\n"
        "  두 시스템이 멀쩡한가만 본다.  변수가 하나뿐이다.\n"
        "\n"
        "바뀐 것 (각 빌드에서 10바이트)\n"
        "  $66E6-$66E7   JSR 오퍼랜드 -> $5FF2\n"
        "  $648D-$648E   JSR 오퍼랜드 -> $5FF5\n"
        "  $5FF2  4C xx xx   JMP 렌더 핸들러\n"
        "  $5FF5  4C xx xx   JMP 폰트 핸들러\n"
        "  $5FF8  A5 5A A5 5A  카나리아\n"
        "\n"
        "  merged-BODY  ->  $5E40 (BODY 프리로더) / $7F50 (BODY 폰트 래퍼)\n"
        "  merged-UI    ->  $5F30 (UI 로더)      / $5CE7 (UI 래퍼)\n"
        "\n"
        "절차\n"
        "  1) [merged-BODY].cue 로드 -> 파워 사이클\n"
        "     본문 한글이 KO 0.2.26 과 똑같이 나오는지\n"
        "     대사를 여러 개 넘기고 장면 전환까지\n"
        "\n"
        "  2) [merged-UI].cue 로드 -> 파워 사이클\n"
        "     액션 메뉴 4개 라벨이 UI 0.5.7 과 똑같이 나오는지\n"
        "     안으로 들어간다 / 보다 / 조사하다 / 대화하다\n"
        "     커서 이동, 선택, 장면 전환, 메뉴 재진입까지\n"
        "\n"
        "판정\n"
        "  둘 다 기존과 동일  -> COMMON 설치와 훅 우회가 무해함이 증명됨\n"
        "                        다음 단계(전환 코드)로 갈 수 있다\n"
        "  하나라도 깨짐      -> 전환 코드를 만들기 전에 여기서 원인을 잡는다\n"
        "                        깨지는 지점(첫 대사/첫 라벨/갱신/재진입)을 기록할 것\n"
        "\n"
        "왜 JMP 인가\n"
        "  JMP 이므로 핸들러의 RTS 가 원래 호출자에게 직접 돌아간다.\n"
        "  반환 규약이 보존되고 COMMON 이 스택을 건드리지 않는다.\n"
        "  두 모듈의 훅 규약 차이(3바이트 vs 10바이트 교체)도 그대로 유지된다.\n"
        "\n"
        "카나리아\n"
        "  $5FF8-$5FFB 가 A5 5A A5 5A 로 유지되는지 감시하면 COMMON 훼손을 잡는다.\n"
        "  감시 Lua 는 별도로 제공한다.\n",
        encoding="utf-8")

    print(f"\n완료: {OUT}")


if __name__ == "__main__":
    main()
