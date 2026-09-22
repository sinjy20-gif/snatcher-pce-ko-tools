#!/usr/bin/env python3
"""배포용 xdelta(VCDIFF) 패치 묶음을 만든다.  받는 쪽에 **파이썬이 필요 없다.**

    python tools/make_xdelta_patch.py 0.7.29
    python tools/make_xdelta_patch.py 0.7.29 --zip

무엇을 내는가
-------------
    dist/snatcher-ko-<판>/
        apply.bat                   ★ CRLF · UTF-8(BOM 없음) · chcp 65001
        README.md                   손으로 쓴다 (판마다 내용이 다르다).  있으면 그대로 둔다
        Snatcher CD-ROMantic (Japan) [KO].cue
        patch/bios.xdelta · track02.xdelta · track24.xdelta · index.json
        xdelta3/xdelta3.exe · 출처.txt

왜 세 개뿐인가
--------------
손대는 것이 BIOS · Track 02 · Track 24 **셋뿐**이다.  나머지 22 트랙은 원본 그대로
쓴다.  Track 24 는 원본 뒤에 자막 팩을 덧붙여 길이가 늘어난다 (원본 구간 변경 0).

⚠ 이 도구는 환경 B 쪽 `tools/make_xdelta_patch.py` 와 **이름이 같다.**
  2026-09-22 에 환경 A에서 따로 쓴 것이다 — 환경 B 판이 묶음에 안 실려 왔다.
  병합 때 둘이 부딪히면 **사람이 판정할 것** (둘 다 살려 두지 말 것).

⚠ 동봉하는 `xdelta3.exe` 는 v3.1.0 (GPL-2.0, `jmacd/xdelta-gpl`).
  환경 B 쪽에는 해시 대조까지 한 v3.2.0 이 있다 — 그게 오면 갈아끼울 것.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / "dist"
XDELTA = ROOT / "tools" / "vendor" / "xdelta3" / "xdelta3.exe"

# 원본 셋.  **해시로 고정한다** -- 이름이 같아도 다른 덤프면 거부한다.
SOURCES = {
    "bios": (
        ROOT / "Mesen_2.2.1_Windows" / "Firmware"
             / "[BIOS] Super CD-ROM System (Japan) (v3.0).pce.JP_ORIGINAL",
        "E11527B3B96CE112A037138988CA72FD117A6B0779C2480D9E03EAEBECE3D9CE",
        "[BIOS] Super CD-ROM System (Japan) (v3.0).pce",
    ),
    "track02": (
        ROOT / "rom(japan)" / "Snatcher CD-ROMantic (Japan)"
             / "Snatcher CD-ROMantic (Japan) (Track 02).bin",
        "A222652F408653B2F0962DAE8BF6B8242D83FBFBD0E059975DCA82D7D576A028",
        "Snatcher CD-ROMantic (Japan) (Track 02).bin",
    ),
    "track24": (
        ROOT / "rom(japan)" / "Snatcher CD-ROMantic (Japan)"
             / "Snatcher CD-ROMantic (Japan) (Track 24).bin",
        "467F122A9C91C95D334CA1993E6A1E5316AD57DBEFDFBBA63DF6BED802D80814",
        "Snatcher CD-ROMantic (Japan) (Track 24).bin",
    ),
}

UNTOUCHED = [f"Snatcher CD-ROMantic (Japan) (Track {n:02d}).bin"
             for n in list(range(1, 25)) if n not in (2, 24)]


def sha(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest().upper()


def dst_for(build: Path, target: str, version: str) -> Path:
    if target == "bios":
        return build / f"Syscard3_galmuri_{version}.pce"
    n = "02" if target == "track02" else "24"
    return build / f"Snatcher CD-ROMantic (Japan) (Track {n}) [KO].bin"


def xrun(*args: str) -> None:
    r = subprocess.run([str(XDELTA), *args], capture_output=True)
    if r.returncode != 0:
        sys.exit(f"xdelta3 실패 ({r.returncode}): {r.stderr.decode(errors='replace')}")


APPLY_BAT = r"""@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion
title Snatcher 한국어 패치 __VER__

set "HERE=%~dp0"
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"
set "SRC=%~1"
if "%SRC%"=="" set "SRC=%HERE%"
if "%SRC:~-1%"=="\" set "SRC=%SRC:~0,-1%"

echo.
echo  ==========================================================
echo   Snatcher (PC Engine CD-ROM2) 한국어 패치  __VER__
echo  ==========================================================
echo.
echo   원본 폴더 : %SRC%
echo   결과 폴더 : %HERE%\out
echo.
echo   * 원본은 읽기만 합니다. 고치지 않습니다.
echo.

set "XD=%HERE%\xdelta3\xdelta3.exe"
if not exist "%XD%" (
  echo  [오류] xdelta3\xdelta3.exe 가 없습니다. 압축을 다 푸셨나요?
  goto :fail
)
if not exist "%HERE%\out" mkdir "%HERE%\out"

rem  --- BIOS 는 이름이 사람마다 달라서 **해시로 찾는다** (256 KB 라 금방이다)
echo  [bios] 원본 BIOS 를 찾는 중...
set "BIOSIN="
for %%D in ("!SRC!" "!HERE!") do (
  for %%F in ("%%~D\*.pce" "%%~D\*.PCE" "%%~D\*.JP_ORIGINAL") do (
    if not defined BIOSIN if exist "%%~F" (
      call :hash "%%~F" GOT
      if /i "!GOT!"=="__BIOS_SSHA__" set "BIOSIN=%%~F"
    )
  )
)
if not defined BIOSIN (
  echo     [오류] 일본판 Super CD-ROM2 System BIOS ^(v3.0^) 을 못 찾았습니다.
  echo            262,144 바이트 · SHA-256 __BIOS_SSHA__
  echo            그 파일을 이 폴더에 넣고 다시 실행해 주세요.
  goto :fail
)
echo     찾음 OK  !BIOSIN!
call :apply bios "!BIOSIN!" "__BIOS_DST__" __BIOS_DSHA__
if errorlevel 1 goto :fail

call :one track02 "__T02_SRC__" "__T02_DST__" __T02_SSHA__ __T02_DSHA__
if errorlevel 1 goto :fail
call :one track24 "__T24_SRC__" "__T24_DST__" __T24_SSHA__ __T24_DSHA__
if errorlevel 1 goto :fail

copy /y "!HERE!\Snatcher CD-ROMantic (Japan) [KO].cue" "!HERE!\out\" >nul

echo.
echo  손 안 댄 트랙 22 개도 out 폴더에 복사할까요?
echo    Y = out 폴더만으로 바로 플레이 가능 ^(약 600 MB 더 씀^)
echo    N = 복사 안 함. out 의 파일 4 개를 원본 폴더에 옮겨 쓰세요
echo.
set "CP="
set /p "CP=복사할까요? [Y/N] : "
if /i "!CP!"=="Y" (
  echo.
  echo  복사 중... 잠시 걸립니다.
  for %%N in (__UNTOUCHED__) do call :copytrack %%N
)

echo.
echo  ==========================================================
echo   완료. 결과는 out 폴더에 있습니다.
echo  ==========================================================
echo.
echo   다음에 할 일
echo.
echo    1. 에뮬레이터에서 out 안의 [KO].cue 를 엽니다.
echo       ^(트랙을 복사 안 하셨으면 out 의 파일 4 개를 원본 폴더로 옮기세요^)
echo    2. BIOS 는 __BIOS_DST__ 를 쓰세요.
echo    3. README 의 [필요한 설정] 을 꼭 켜세요. 안 켜면 화면이 깨집니다.
echo       - 아케이드 카드 켜기        ^(필수^)
echo       - 스프라이트 한 줄 제한 해제 ^(사실상 필수^)
echo       - CPU 오버클럭 10          ^(강력 권장^)
echo.
pause
exit /b 0

:copytrack
rem  괄호가 든 경로가 for/if 블록 안에서 깨지므로 **부르는 자리를 따로 둔다**
set "_T=Snatcher CD-ROMantic (Japan) (Track %~1).bin"
if exist "!SRC!\!_T!" (
  copy /y "!SRC!\!_T!" "!HERE!\out\" >nul
  echo     Track %~1
) else (
  echo     [건너뜀] Track %~1 을 못 찾았습니다
)
exit /b 0

:one
rem  %1=이름  %2=원본이름  %3=결과이름  %4=원본SHA  %5=결과SHA
rem  ⚠ 여기서 %SRC% 를 쓰면 안 된다 -- 경로의 괄호가 if 블록을 일찍 닫는다.
rem    !SRC! 는 블록을 다 읽은 뒤에 펴지므로 안전하다.
set "IN=!SRC!\%~2"
echo  [%~1] %~2
if not exist "!IN!" (
  echo     [오류] 원본을 못 찾았습니다.
  echo            !IN!
  exit /b 1
)
call :hash "!IN!" GOT
if /i not "!GOT!"=="%~4" (
  echo     [오류] 원본이 다릅니다. 이 패치는 이 덤프에만 맞습니다.
  echo            필요 %~4
  echo            실제 !GOT!
  exit /b 1
)
echo     원본 확인 OK
call :apply "%~1" "!IN!" "%~3" %~5
exit /b %errorlevel%

:apply
rem  %1=이름  %2=원본 전체경로  %3=결과이름  %4=결과SHA
set "OUT=!HERE!\out\%~3"
"!XD!" -d -f -s "%~2" "!HERE!\patch\%~1.xdelta" "!OUT!"
if errorlevel 1 (
  echo     [오류] 패치 적용에 실패했습니다.
  exit /b 1
)
call :hash "!OUT!" GOT
if /i not "!GOT!"=="%~4" (
  echo     [오류] 결과가 기대값과 다릅니다. 디스크 공간을 확인해 주세요.
  exit /b 1
)
echo     결과 확인 OK  -^>  out\%~3
echo.
exit /b 0

:hash
rem  %1=파일  %2=담을 변수 이름.  certutil 은 윈도우에 기본으로 있습니다
set "_H="
for /f "skip=1 delims=" %%A in ('certutil -hashfile "%~1" SHA256 2^>nul') do (
  if not defined _H (
    set "_L=%%A"
    set "_L=!_L: =!"
    echo !_L!| findstr /r "^[0-9a-fA-F][0-9a-fA-F]*$" >nul && set "_H=!_L!"
  )
)
set "%~2=!_H!"
exit /b 0

:fail
echo.
echo  중단했습니다. 위 오류를 확인해 주세요.
echo.
pause
exit /b 1
"""


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("version")
    ap.add_argument("--zip", action="store_true", help="다 만든 뒤 zip 으로 싼다")
    args = ap.parse_args()

    build = ROOT / "build" / "patch" / args.version
    if not build.is_dir():
        sys.exit(f"빌드가 없다: {build}")
    if not XDELTA.is_file():
        sys.exit(f"xdelta3.exe 가 없다: {XDELTA}")

    out = DIST / f"snatcher-ko-{args.version}"
    (out / "patch").mkdir(parents=True, exist_ok=True)
    (out / "xdelta3").mkdir(parents=True, exist_ok=True)

    print(f"판 {args.version}  ->  {out}")
    print(f"xdelta3 {sha(XDELTA)[:16]}\n")

    targets, subs = [], {"__VER__": args.version}
    keys = {"bios": "BIOS", "track02": "T02", "track24": "T24"}
    for name, (src, want, src_name) in SOURCES.items():
        if not src.is_file():
            sys.exit(f"원본이 없다: {src}")
        got = sha(src)
        if got != want:
            sys.exit(f"{name}: 원본 해시가 다르다\n  필요 {want}\n  실제 {got}")
        dst = dst_for(build, name, args.version)
        if not dst.is_file():
            sys.exit(f"결과물이 없다: {dst}")
        dst_sha = sha(dst)
        patch = out / "patch" / f"{name}.xdelta"

        # 소스 창을 파일 하나가 다 들어가게 잡는다 (기본 64 MiB 는 Track 에 모자라다)
        xrun("-e", "-9", "-S", "lzma", "-f", "-B", "268435456",
             "-s", str(src), str(dst), str(patch))

        # ★ 되풀어 검산한다.  만든 즉시, 우리 손이 아니라 배포될 그 exe 로.
        back = patch.with_suffix(".verify")
        xrun("-d", "-f", "-s", str(src), str(patch), str(back))
        ok = sha(back) == dst_sha
        back.unlink()
        if not ok:
            sys.exit(f"★ {name}: 되풀기 검산 실패 -- 내보내지 않는다")

        ratio = patch.stat().st_size / max(dst.stat().st_size, 1) * 100
        print(f"  {name:8s} {patch.stat().st_size:>9,} B  "
              f"({ratio:5.2f}% of {dst.stat().st_size:,})  되풀기 OK")

        k = keys[name]
        subs[f"__{k}_SRC__"] = src_name
        subs[f"__{k}_DST__"] = dst.name
        subs[f"__{k}_SSHA__"] = want
        subs[f"__{k}_DSHA__"] = dst_sha
        targets.append({
            "target": name, "version": args.version,
            "src_name": src_name, "src_size": src.stat().st_size, "src_sha256": want,
            "dst_name": dst.name, "dst_size": dst.stat().st_size, "dst_sha256": dst_sha,
            "patch": f"patch/{name}.xdelta", "patch_bytes": patch.stat().st_size,
        })

    (out / "patch" / "index.json").write_text(json.dumps({
        "version": args.version, "format": "VCDIFF (xdelta3)",
        "xdelta3_sha256": sha(XDELTA),
        "targets": targets, "untouched_tracks": UNTOUCHED,
    }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    # ★ apply.bat 은 **CRLF · UTF-8 BOM 없음**.  LF 면 cmd.exe 파서가 깨지고
    #   BOM 이 있으면 첫 줄 앞에 쓰레기가 찍힌다.
    subs["__UNTOUCHED__"] = " ".join(
        f"{n:02d}" for n in range(1, 25) if n not in (2, 24))
    text = APPLY_BAT
    for k, v in subs.items():
        text = text.replace(k, v)
    (out / "apply.bat").write_bytes(
        "\r\n".join(text.splitlines()).encode("utf-8") + b"\r\n")

    shutil.copy2(XDELTA, out / "xdelta3" / "xdelta3.exe")
    (out / "xdelta3" / "출처.txt").write_text(
        "xdelta3 v3.1.0 (VCDIFF, RFC 3284)\n"
        "GPL-2.0 · Joshua MacDonald\n"
        "https://github.com/jmacd/xdelta-gpl\n"
        "공식 배포:  https://github.com/jmacd/xdelta-gpl/releases/tag/v3.1.0\n"
        "소스도 같은 곳에 있습니다.\n\n"
        f"동봉본 SHA-256  {sha(XDELTA)}\n",
        encoding="utf-8")

    cue = next(build.glob("*.cue"), None)
    if cue:
        shutil.copy2(cue, out / cue.name)
    if not (out / "README.md").is_file():
        print("\n  ⚠ README.md 가 없다 -- 판마다 내용이 달라 손으로 쓴다")

    if args.zip:
        z = DIST / f"snatcher-ko-{args.version}.zip"
        with zipfile.ZipFile(z, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
            for f in sorted(out.rglob("*")):
                if f.is_file():
                    zf.write(f, f"snatcher-ko-{args.version}/"
                                f"{f.relative_to(out).as_posix()}")
        print(f"\n  zip  {z}  {z.stat().st_size:,} B")

    print(f"\n  완료 · {out}")


if __name__ == "__main__":
    main()
