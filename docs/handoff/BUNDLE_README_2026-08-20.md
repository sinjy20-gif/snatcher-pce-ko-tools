# 환경 A에 가져갈 묶음 — 2026-08-20 환경 B분

## 먼저 읽을 것

**`docs/handoff/SNATCHER_VOICE_RAM_2026-08-20.md`** — 오늘 인계서. 이거 하나면 이어서
일할 수 있다.

---

## ⚠ 이 묶음을 푸는 법 — 통째로 덮으면 안 된다

과거에 물린 적이 있다: **묶음을 풀어도 라이브 트리가 다 안 덮인다.** `snatcher_tool\`
만 덮이고 나머지는 손으로 옮겨야 한다. 낡은 `extraction\` 으로도 빌드가 *성공* 하기
때문에 조용히 옛것으로 돌아간다.

| 묶음 안 | 환경 A 트리 | 어떻게 |
|---|---|---|
| `snatcher_tool\` | `C:\snatcher\snatcher_tool\` | 덮어쓰기 OK |
| `lua\` | `C:\snatcher\lua\` | 덮어쓰기 OK |
| `tools\` | `C:\snatcher\tools\` | 덮어쓰기 OK |
| `docs\handoff\` | `C:\snatcher\docs\handoff\` | 덮어쓰기 OK |
| `build\bios_font\` | `C:\snatcher\build\bios_font\` | 덮어쓰기 OK |
| `extraction\patch\static\` | 같은 자리 | **손으로 확인하고 덮을 것** |
| `extraction\translation\` | 같은 자리 | **손으로 확인하고 덮을 것** |
| `build\patch\0.4.5.4\` | 같은 자리 | 새 폴더 |
| `dump\*.tsv` | `C:\snatcher\dump\` | 참고용. 안 덮어도 됨 |

⚠ **`snatcher_tool\translation\snatcher_ko_master.tsv` 를 덮기 전에 반드시 확인할 것.**
환경 A에서 번역한 것이 있으면 그게 날아간다. 이 묶음의 마스터는 **오늘 16:06 환경 B 기준**
이다 (4,679 행 / 3,328 레코드 / 검토 4,073).

---

## 담긴 것

### 인계서
```
docs/handoff/SNATCHER_VOICE_RAM_2026-08-20.md   <- 오늘 것
docs/handoff/                                   <- 전체 (참조용)
```

### 스튜디오
```
snatcher_tool/studio_source/            소스 본체.  오늘 MainForm.cs 3 군데 수정
snatcher_tool/SnatcherTranslationStudio.exe   실행본 (빌드 통과분)
```

`bin` · `obj` · `_publish` · `portable_release` 는 뺐다 — 같은 exe 가 세 벌 더 들어가
293 MB 가 된다. 다시 빌드하려면 `studio_source\BUILD_EXE.cmd`.

### 수집기 · 프로브 · 자막
```
snatcher_tool/mesen/runtime_text_audit_0.2.2.lua   <- 오늘 것.  이걸 쓸 것
snatcher_tool/mesen/runtime_text_audit_0.2.1.lua      직전 (그대로 남겨둠)
snatcher_tool/mesen/PROBE_ARENA_0.1.3.lua             자막의 관문.  미실행
lua/PROBE_ADPCM_RAM_0.1.0.lua / 0.1.1.lua             오늘 만든 것
lua/SUBTITLE_DRAW_0.2.0.lua                           화면에 실제로 그려진 자막
lua/  나머지 프로브 전부
```

### 도구
```
tools/build_runtime_master.py       <- 오늘 2 군데 수정 (§3)
tools/ram_adpcm_to_wav.py           <- 오늘 새로 만듦
tools/build_bios_font_patch.py      BIOS 폰트 굽기 (해태 로고 포함이 기본)
tools/build_bios_hangul_map.py      슬롯맵 만들기
tools/build_bios_boot_logo.py       부팅 로고
tools/build_bios.py
tools/transcribe_adpcm.py           ⚠ 아직 옛 폴더를 본다.  고쳐야 함
tools/extract_adpcm.py              ⚠ 옛 방식(디스크 좌표).  이제 안 쓴다
```

### BIOS
```
build/bios_font/Syscard3_galmuri.pce        <- 현역.  08-20 13:45
build/bios_font/Syscard3_galmuri_haitai.pce    해태 로고판
build/bios_font/hangul_slot_map.tsv         <- 08-20 08:22.  디스크와 짝이어야 함
build/bios_font/galmuri_ks_2350.bin / .tsv     글리프 팩 (16x16, KS 순서)
build/bios_font/*.bak                          이전 판들
```

⚠ **BIOS 와 디스크는 같은 `hangul_slot_map.tsv` 에서 함께 나와야 한다.** 어긋나면
화면 글자가 깨진다. 전에 Mesen 펌웨어가 08-19 판이고 빌드가 08-20 슬롯맵이라 19 자가
깨졌었다. 빌드하면 `Syscard3_galmuri.pce` 를 **Mesen Firmware 폴더에도 복사**할 것.

### 번역 데이터
```
snatcher_tool/translation/snatcher_ko_master.tsv    현역 마스터
snatcher_tool/translation/voice_events.tsv          음성 이벤트 (가공)
snatcher_tool/translation/SPEAKER_STYLE.md          화자별 말투 기준.  번역 전 필독
snatcher_tool/logs/voice_events_raw.tsv             원시.  오늘 열 2 개 추가됨
snatcher_tool/logs/voice_events_raw.tsv.0.2.1.bak   그 전 원본
snatcher_tool/logs/voice_clips/                     오늘 뜬 클립 5 개
```

### 빌드
```
build/patch/0.4.5.4/            CD 전체 (643 MB)
extraction/patch/static/        빌드 소스
extraction/translation/         빌드 입력 대장
```

### 오늘 측정한 것
```
dump/probe_adpcm_ram_0_1_0.tsv        memType 107 개 목록 · pceAdpcmRam=63
dump/probe_adpcm_ram_0_1_1.tsv        readAddress 기준 덤프 실측
dump/frame_budget.tsv                 7,455 프레임 · 넘김 0 · avg==max
dump/runtime_master_20260820_155902.tsv   새 빌더 결과 (설치 안 함)
dump/runtime_text_audit_raw_v020.tsv  오늘 원시 대사 로그
```

---

## 환경 A에서 할 순서 (요약)

인계서 §6 에 자세히 있다. 짧게:

**1. 수집** — Mesen 에서 `runtime_text_audit_0.2.2.lua` (0.2.1 아님).
`snatcher_tool\logs\voice_clips\` 폴더가 있어야 한다.

**2. 마스터** — 먼저 보고만:
```
python C:\snatcher\tools\build_runtime_master.py
```
`로그 밖 현역 레코드 보존: N행` 이 뜨는지 **반드시 확인.** 0 이면 멈출 것.
이상 없으면 `--write --install`.

**3. 음성 WAV**
```
python C:\snatcher\tools\ram_adpcm_to_wav.py --write
```

---

## 오늘 한 줄 요약

게임 음성을 **대사 단위로 온전히** 뽑을 수 있게 됐다 (ADPCM RAM 직접 덤프).
덤으로 마스터가 1,919 행을 잃을 뻔한 구멍과, 대사 28 개가 재수집으로도 안 채워지던
원인을 같이 잡았다.
