# 빌드 체인 — 실제로 도는 경로와 낡는 구멍들 (2026-09-02)

## 0. 30초 요약

```
결과   0.4.6.68 에서 스튜디오 음성 자막 편집분이 처음으로 화면에 나왔다 (확인 완료)
비용   같은 것을 세 번 구웠다.  원인은 전부 "파생물이 조용히 낡는다" 한 가지였다
구멍   LBA 색인(막음) · _keyed(막음) · 팩 자리(구조 그대로 남음)
규모   build_*.py 138 개 · build_snatcher_*.py 59 개 · Lua 598 개
       그중 실제로 도는 것은 대여섯 개다.  나머지가 정본을 가린다
```

---

## 1. ★ 실제로 도는 체인 (이것만 쓰면 된다)

```
[대사]
  snatcher_ko_master.tsv (스튜디오)
    -> tools/build_snatcher_0_4_6_61_dictionary_key_vram.py        3 단계
         step0  LBA 색인 재생성      (2026-09-02 에 편입.  전에는 수동이었다)
         step1  마스터 -> 디스크      EXPERIMENT/0.4.6.61-...-unpatched
         step2  헬퍼 preload         0.4.6.61-reviewed-dictionary
         step3  상주부 + key-VRAM    0.4.6.61-dictionary-key-vram   <- 기준판

[자막]
  voice_subtitles.tsv (스튜디오)
    -> tools/sync_voice_subtitles_keyed.py --write      ★ 손으로 먼저.  아직 안 묶임
    -> tools/build_subtitle_set.py                      팩 + 파생물 한 벌, 태그 발급
    -> tools/build_snatcher_0_4_6_63_all_in_one.py --version <V> --tag <TAG>
    -> tools/patch_track24_subtitle_pack.py <V> --write   ★ 빼먹으면 디스크에 옛 팩
    -> tools/patch_bios_cpu_cache.py <V> --write         ★ 빼먹으면 챕터1 화면 파손
```

### 1-1. 오늘 쓴 환경변수

```
SNATCHER_SUBTITLE_SKIP_OVERSIZE=1     19 칸 넘는 자막 76 개를 빼고 굽는다
```

기본은 fail-closed 다.  결국 다 넣어야 하므로 조용히 빠지면 안 된다.

### 1-2. 걸리는 곳

```
step3 이 "output already exists" 로 거부한다
    -> 폴더를 지우지 말고 옆으로 민다:  mv ...-key-vram ...-key-vram.old_<시각>
       (오늘 .65 빌더를 못 찾아 헤맸다.  지우면 복구가 안 된다)
```

---

## 2. ★ 팩 자리 주기 — 아직 안 막힌 구멍

기준판(`0.4.6.61-dictionary-key-vram`)의 `bios_preload.json` 이 **팩에 내줄 섹터 수**를
정한다.  `.63` 은 그 기준판을 복사해 자막만 얹으므로 자리를 새로 못 잡는다.

```
팩이 그 자리보다 커지면  ->  patch_track24 가 "팩이 자리보다 크다" 로 중단
해결                     ->  기준판부터 다시 굽는다 (그때의 팩 크기로 자리를 잡는다)
```

오늘 이 주기를 **두 번** 돌았다.

```
1 회차   팩 189,119 B  >  자리 186,368 B (91 섹터)   -> 기준판 재빌드 -> 93 섹터
2 회차   팩 192,255 B  >  자리 190,464 B (93 섹터)   -> 기준판 재빌드 -> 94 섹터
최종     팩 192,255 B  <= 자리 192,512 B (94 섹터)   통과
```

★ 자막을 늘릴 때마다 이 왕복이 생긴다.  기준판이 자리를 넉넉히(예: 100 섹터) 잡게
  하면 사라진다.  아직 안 했다.

---

## 3. 오늘 막은 구멍 둘

### 3-1. LBA 색인이 수동 단계였다

빌드가 색인을 다시 안 만들어서, 그 자리에 있던 낡은 색인이 조용히 실렸다.
`.61` 체인에 `step0` 으로 넣었다.  이제 빌드마다 자동으로 다시 만든다.

### 3-2. `voice_subtitles_keyed.tsv` 가 자기 출력을 정본으로 읽었다

```python
# build_voice_keys.py
if OUT_SUBS.exists():
    old_subs = read_tsv(OUT_SUBS)      # "이전에 만든 열쇠 표가 있으면 그쪽이 정본"
```

그 도구의 목적은 `event_id`(재생 한 번) -> `key`(음성 자체) **이관**이었다.  이관이
끝난 뒤로는 스튜디오 편집을 들여올 길이 없어 조용히 낡았다.

```
voice_subtitles.tsv        21:43  2,213 행   스튜디오가 저장 (정본)
voice_subtitles_keyed.tsv  08:28  2,166 행   팩이 읽음 (낡음)
   자막이 다른 행 117 · 정본에만 53 · 파생에만 6
```

두 표는 **첫 열 이름만 다르다** (`event_id` vs `key`).  나머지 아홉 열과 식별자
형식이 같다.  그래서 `tools/sync_voice_subtitles_keyed.py` 를 만들었다.

★ 원칙: **마스터가 언제나 최신이고 정본이다.  승계하지 않는다.**
  파생에만 있던 6 행은 옛 분할의 꼬리 조각(`걸까요.` `보입니다`)이라 버렸다.

⚠ 아직 `build_subtitle_set.py` 앞에 자동으로 묶지 않았다.  **손으로 먼저 돌려야 한다.**

---

## 4. 요물이 된 이유 — 숫자

```
build_snatcher_*.py            59
build_*.py 전체               138
lua/ 전체                     598   (lua/SUB 267)

frozen_8F20AF38 을 하드코딩    8    build_pack_lba_index · 0_4_6_40_native_preload
                                    0_4_6_43 · 0_4_6_47 · 0_4_6_62_live_subs
                                    build_subtitle_engine_vdc_rearm · build_subtitle_set
낡은 스냅샷 경로를 든 것        5    0_4_5_11 · 0_4_5_12 · 0_4_6_13 · 0_4_6_14 · 0_4_6_61
```

`0.4.6.13-reviewed/translation` 스냅샷은 `.13`~`.60` 이 **47 개 빌드 내내** 깔고 있던
디스크의 출처다.  `.61` 이 처음으로 스튜디오와 연결됐다 (15,694 행 -> 15,861 행).

★ `build_snatcher_0_4_5_12_reviewed_dictionary.py` 는 오늘 번들 동기화로 갱신되면서
  스냅샷 경로가 없어지고 스튜디오를 기본으로 보게 바뀌었다 (환경변수로 override 가능).

---

## 5. 정리 제안 (착수 안 함)

한 번에 뒤엎지 말고 오늘 데인 순서대로.

```
1  현행 체인을 한 장으로 못박는다              <- 이 문서 §1
2  파생물 자동화
     sync_voice_subtitles_keyed 를 build_subtitle_set 앞에 묶는다
     기준판이 팩 자리를 넉넉히 잡게 한다 (§2 왕복 제거)
3  안 쓰는 빌더를 tools/_attic/ 로 격리        ★지우지 않는다
4  frozen_8F20AF38 8 곳을 하나씩 판정          아직 필요한 곳 / 그냥 관성인 곳
```

---

## 6. 최종 산출물

```
build/patch/0.4.6.68/
    Syscard3_galmuri_0.4.6.68.pce      BIOS 캐시 패치 후 sha 548F1CDB054DF87D
    Snatcher CD-ROMantic (Japan) [KO].cue
    팩 태그 E5142D3F124AB662 · 192,255 B · 94 섹터

들어간 것
    스튜디오 음성 자막 편집분 117 행 갱신 · 53 행 추가 · 옛 꼬리 6 행 제거
    런타임 키 충돌 3 쌍 -> LBA 로 갈림 · 미해결 0
    같은 LBA 버킷 병합 4 곳 (957 keys / 953 routes)
    공통자리 override 4 음성 (생성기 규칙으로 영구화)
    LBA 색인 교정 158 건
    마스터 3492D909AEF69358 (검토 O 16,074 행 전량)

뺀 것 (알고 뺐다)
    19 칸 초과 자막 76 개      build/cutscene_subs/pack_over_capacity.tsv
    폭 192 px 초과 9 개        build/cutscene_subs/pack_overwidth.tsv  (경고만, 실림)
    안전자리 없는 35 음성
```

---

## 7. 오늘 고친 파일

```
build_subtitle_pack.py                 주인표 출력 + 충돌 관문 2 층 판정
build_adpcm_native_subtitle_table.py   주인별 묶기 + LBA 버킷 병합 + --skip-missing-lba
build_adpcm_lba_master_index.py        포화 길이 -> 실측 바이트 + 전체 대응표
build_vram_key_bases.py                override 훅 + 검증 + BOM(utf-8-sig) 수정
build_snatcher_0_4_6_61_...py          step0 (LBA 색인 자동 재생성)
tools/vram_key_base_overrides.tsv      공통자리 규칙          (신규)
tools/sync_voice_subtitles_keyed.py    마스터 -> _keyed 재생성 (신규)
tools/lookup_voice_line.py             자막 조각으로 키·진단 조회 (신규)
```

팩 형식 · 스트라이드 13 · 디스패처 · 255 B 조각 카운터는 **하나도 안 건드렸다.**
