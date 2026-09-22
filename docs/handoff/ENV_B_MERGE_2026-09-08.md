# `ENV_B\` 병합 영수증 — 2026-09-08 저녁

환경 B에서 들고 온 `C:\snatcher\ENV_B\` 를 환경 A 작업본에 반영하고 폴더를 지웠다.
도구: `tools/sync_from_office_20260908.py` (보고 → `--write`).

## 무엇으로 판정했나 — mtime 이 아니다

메모리 `snatcher_bundle_merge_time_window_rule` 대로 **직전 반대방향 묶음**을
대조군으로 썼다.

```
대조군   SNATCHER_ENV_B_20260908_CDDA_REARM   (09-07 23:32 환경 A -> 환경 B)
번들     ENV_B\SNATCHER_ENV_A_20260908_SHAKE   (09-08 16:36 환경 B -> 환경 A)
```

라이브 == 대조군이면 환경 A는 보낸 뒤로 그 파일을 안 건드린 것이므로, 번들과의
차이는 전부 환경 B의 새 작업이다 → 덮어도 손실 0 이 **증명된다.**

결과: **CONFLICT 0.** 182 파일 중 125 반영 · 1 보류 · 56 이미 동일.

## 반영한 것

| 자리 | 개수 | 내용 |
|---|---:|---|
| `dump/` | 85 | 09-08 주행 로그 + gfx 캡처 |
| `lua/SUB/` | 8 | `0.5.184` ~ `0.5.191` 프로브 |
| `tools/` | 8 신규 + 8 갱신 | `build_no_template_test.py` 등 · 하드링크 고침 |
| `docs/handoff/` | 2 | `SHAKE_ROOT` · `SHAKE_REDIAG` |
| `snatcher_tool/translation/` | 3 갱신 + 1 | 마스터 · 음성 · CD-DA 자막 |
| `snatcher_tool/logs/` | 3 | 병합 보고 · 번역할 42 레코드 |
| `extraction/patch/static/` | 1 | `build_ac_dynamic_0_1_14.py` sentinel 자리 고침 |
| `_side/banner/` | 5 | 스내처와 무관 — 쌀가공식품 실태조사 배너 |

덮기 전 사본: `_backup_before_office_merge_20260908_185339\` (13 파일)

★ `ENV_B\` **뿌리**에도 `SNATCHER_SHAKE_REDIAG_2026-09-08.md` 가 따로 있었다
(18:38 · 2,979 B). 번들 안 `docs/handoff/` 판(16:24 · 2,339 B)보다 **뒤에 고친
것**이고 `zeroac 사용자 시험` 절이 통째로 더 있다. 순수 추가라 그쪽을 설치했다.
동기화 도구는 번들 안 폴더만 훑으므로 이 파일을 못 본다 — 다음에도 **묶음 뿌리에
낱개로 놓인 파일**을 따로 확인할 것.

## ★ 손으로 판정한 것 셋

### `snatcher_tool/translation/cdda_subtitles.tsv` — 줄어드는데 덮었다

행이 **735 → 708** 로 줄어 자동 규칙만으로는 위험해 보였다. 키를 `(track, part)`
로 잡으니 트랙 06 part 60~75 · 트랙 07 part 50~60 이 사라진 것처럼 보였고,
**사라진 27 행 전부에 번역이 들어 있었다.**

그런데 환경 B판 part 40~59 를 나란히 놓으니 답이 나온다 — 환경 A의 짧은 조각들이
한 줄로 합쳐진 것이다:

```
환경 A   40 바운티 헌터 등록 시에 / 41 기재된 각 데이터는 / 42 전부 거짓 데이터로,
환경 B 41 자, 이제부터가 본론이다.   ← 조각을 합치고 싱크를 다시 잡았다
환경 A   마지막 161.159   환경 B 마지막 161.330   ← 끝 시각은 오히려 환경 B가 더 뒤
```

소유자 확인: *"자막 조각들 내가 합쳐서 정리하고 싱크도 맞춘거니 걍 덮으면 됨"*
→ 잃은 대사 없음. 행수만 준다. **덮었다.**

⚠ 교훈: 행수·크기·키집합은 거짓말한다. 줄어드는 TSV 는 **나란히 놓고** 볼 것.

### 음성 마스터 — 환경 B판이 최신

소유자 확인: *"음성마스터는 환경 B께 그냥 최신임"* →
`snatcher_ko_master.tsv`(미수집 63 행 병합됨) · `voice_subtitles.tsv` 덮었다.

### `snatcher_tool/logs/runtime_missing_text_raw_v011.tsv` — ★보류

유일하게 **양쪽 다 오늘 늘어난** 파일이다. 대조군에 없어서 가를 수 없다.

```
환경 A만 있는 줄   234      (오늘 08:13 부터 켜 둔 Mesen 수집기가 쌓았다)
환경 B만 있는 줄 334
어느 쪽도 다른 쪽의 상위집합이 아니다
```

라이브를 그대로 두고 환경 B 것을 옆에 뒀다:

    snatcher_tool/logs/runtime_missing_text_raw_v011.tsv.office_20260908

합치려면 두 파일을 union 한 뒤 `merge_missing_text.py` 를 다시 돌리면 된다.
마스터를 건드리는 일이라 자동으로 하지 않았다 (`docs/MERGE_CHECKLIST.md` §1).

## 디스크 판 둘

`ENV_B\patch\` 는 복사가 아니라 **이동**했다 (같은 볼륨이라 즉시).

```
build/patch/0.6.2                    ← SHAKE 문서들이 기준으로 삼는 판
build/patch/0.6.3-rc1-adpcm-delay    ← CHD 포함
```

## 안 가져온 것과 그 근거

`SNATCHER_STUDIO_PORTABLE_20260908_1656` (865 MB) 은 **고유한 것이 없다.**

```
translation/*.tsv (46)      환경 A 또는 SHAKE 번들과 sha256 전부 일치
build/cutscene_subs (2)     환경 A와 일치
snatcher_tool/logs (1600)   1,596 환경 A에 이미 있음 · 3 은 SHAKE 번들로 들어옴
                            1 (adpcm_reuse_verify_20260907_140423.tsv) 만
                            포터블 전용 -> 건져서 넣었다
```

스튜디오 exe 는 안 덮었다 — 포터블은 self-contained 판(154 MB)이고 환경 A는
framework-dependent(71 MB)라 배포 형태가 다르다. 환경 B가 스튜디오 **소스**를
고친 흔적은 번들에 없다.

zip 셋은 지우기 전에 폴더와 대조했다 — 항목 184 / 1,651 / 74, 누락 0 · 크기불일치 0.

## 기억

```
+ ~/.claude/.../memory/snatcher_shake_root_ac_redraw.md   (새 메모리)
+ MEMORY.md 색인 한 줄
+ _claude_memory/MEMORY_office_20260908.md                (환경 B 색인 47줄 보존)
```

환경 B `MEMORY.md` 로 환경 A 것을 덮지 **않았다.** 두 기억 저장소는 파일 이름이 서로
다르다 — 덮었으면 환경 A의 19 개 포인터가 전부 죽은 링크가 된다.

메모리 본문의 description 은 고쳐서 넣었다. 원문은 "그림 흔들림의 뿌리" 라고
단정하는데, 같은 날 36 분 뒤에 나온 `SHAKE_REDIAG` 가 그 판정을 철회한다
(`noexpand` · `zeroac` 둘 다 흔들림이 남는다). 철회 사실을 본문에도 붙였다.

## 남은 일

1. ★ `runtime_missing_text_raw_v011.tsv` 두 판 union → `merge_missing_text.py`
2. ~~`build/patch` 하드링크 정리~~ — **끝냈다.** 800 개를 묶어 **17.52 GiB** 회수
   (C: 28 GB -> 46 GB). 영수증 `build/patch/_dedupe_receipt_20260908_190114.json`.
   원본 트랙은 읽기전용 820 개로 세웠다. `[KO]` 트랙과 `.pce` 는 링크수 1 로 그대로.
3. SHAKE 인계서 §8 — 원본 일본판 BIOS 대조군으로 `0.5.191-vdc-cost.lua`
   ⚠ Firmware 에서 `...pce.JP_ORIGINAL` 을 **명시적으로** 고를 것
