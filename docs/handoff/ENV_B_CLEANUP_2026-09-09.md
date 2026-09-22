# 환경 B 정리 · 환경 이동 보고 — 2026-09-09

소유자 지시: 짐 싸고, **정식판만 남기고 나머지는 소스 재현 가능하게 하고 철거**,
압축파일·필요 없는 것 정리, 환경 B는 컴팩트하게 유지.

## 1. 환경 A에 가져갈 짐

```
C:\snatcher\SNATCHER_ENV_A_20260909.zip
   309,511,087 B (295 MB) · 항목 3,119
   SHA256  3F6FDF4EBF8898496F16B01D614A831F47D20259C70D54832DE4B30D5D17D3C9
```

풀린 폴더도 `SNATCHER_ENV_A_20260909\` 에 그대로 있다.

검증: zip 무결성 OK · 항목수 zip 3,119 = 폴더 3,119 ·
핵심 8 개(BIOS 4 · 스튜디오 exe · START_HERE 2 · PROBE README)를 zip 안에서
직접 해시 떠 디스크와 대조 → 전부 일치.

`tools/pack_home_20260909.py` 를 다시 돌려 최신으로 뽑았고, 패커가 안 담는
**PROBE_ANDROID/** 를 얹었다 (오늘 16:44 DAY 문서 이후 산출물이라 어디에도
안 적혀 있었다).

```
GAME_BUILD/0.6.4                  정식 출하 (Track02/24 + cue + BIOS)
GAME_BUILD/0.6.3-gfx-native-r5    GFX 진단판 + nohook BIOS
project/ · snatcher_tool/ · MEMORY/
PROBE_ANDROID/  cores 5 · observations 2 · README    ★새로 얹음
```

⚠ 오디오 트랙 01·03~23 은 안 실었다.  환경 A의 기존 빌드에서 복사해야 CUE 가 열린다
   (`00_START_HERE.md` §"먼저" 참고).

## 2. 철거

원장: `_archive/build_records/DELETED_BUILDS_2026-09-09.md`
      — 폴더별 **BIOS SHA256 지문 + 재현 명령**을 다 적었다.

```
build/patch 15 개 폴더        rc10~rc12 · rc2 · rc3 · 0.6.2 · 0.6.3 계열 4 ·
                             진단 5(noexpand zeroac notpl scan_0B scan_FF)
build/patch/patch.zip         1.55 GB  위 두 판의 통짜 사본
build/android-ndk-r30-*.zip   0.68 GB  toolchains 에 이미 풀려 있음
build/studio_portable_publish 0.14 GB  현행 exe 는 snatcher_tool/ 에 있음
_bundle/ (스튜디오 portable)   577 MB
이관 묶음·zip 5 종             옛 환경 A↔B 왕복분
루트 프로브 .so 5 · tsv · CLEAN_NAME_TEST     오늘 짐에 사본 있음
```

```
디스크 여유   5.15 GB  ->  11.65 GB   (회수 6.50 GB)
프로젝트      27.53 GB ->  15.22 GB
```

## 3. 남긴 것 — 지우면 안 된다

```
build/patch/0.6.4                                   ★정식 출하
build/patch/EXPERIMENT/0.4.6.61-reviewed-dictionary-unpatched   모든 빌드의 base_build
build/patch/0.4.6.61-dictionary-key-vram            사슬 입력 (대사 번역 기준판)
build/patch/0.4.6.61-reviewed-dictionary            사슬 입력
build/patch/ac_0.1.12-source-...                    사슬 입력
build/patch/0.4.5.9-collection-base · TEST          import 용 껍데기 -- 없으면 사슬이 죽는다
build/toolchains/android-ndk-r30                    프로브 코어 재빌드에 필요
build/research/beetle-pce-libretro                  clone 6d6a35eb
dump/ · rom(japan)/ · _archive/                     관측 원자료 · 원본 디스크 · 되돌리기
```

## 4. 정리 후 검증

```
0.6.4      pce 2 · cue 1 · bin 24 · cue 참조 미해결 0
0.6.4 BIOS 0F7977990BA2A2FD…   (짐 zip 안의 것과 일치)
사슬       import OK
짐 zip     무결성 OK · 3,119 항목
```

## 5. 판단 보류 (다음에)

```
dump_home/     458 MB  09-02 환경 A dump 사본.  이후 무변경.  환경 A에 원본이 있을 것으로
                       보이나 확인 못 해 남겼다
_archive 8월분 ~580 MB _rescued_20260828 · SNATCHER_KO_HANDOFF_2026-08-12 ·
                       _not_snatcher_20260828.  되돌리기용이라 손대지 않았다
```

## 6. 환경 B 업무 파일은 손대지 않았다

해양수산 통계연보 · 쌀가공식품 실태조사 · 농업법인 · 배너 등 루트의 업무 파일은
전부 그대로다.
