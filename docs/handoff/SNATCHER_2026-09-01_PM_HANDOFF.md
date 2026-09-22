# Snatcher 2026-09-01 오후 인계서 — 빌드 체인 복구 · 마스터 충돌 · 스튜디오

> 오전(671 B 진범·네이티브 이식)은 `SNATCHER_CPU_CACHE_ROOT_CAUSE_2026-09-01.md` 에 있다.
> 이 문서는 그 뒤 오후 작업이다.

---

## 0. 30초 요약

```
★ 마스터 -> 디스크 경로가 끊겨 있었다.  환경 A에서 파일 하나 가져와 복구했다
★ 0.4.6.61 빌드는 버킷 508 하나 때문에 아직 막혀 있다 (3 개 초과)
★ 빌드가 머리 줄 33 개를 **경고 없이** 하나로 통일하고 있다
  스튜디오 CD-DA 탭 재배치 · 음성/CD-DA 검토 열 추가
  음성 클립이 8.2 초에서 잘리던 것 -- 다른 세션이 0.1.5 로 해결
```

---

## 1. ★ 빌드 체인이 끊겨 있었다 (복구됨)

`build_snatcher_ko_0_4_5_8.py` 가 없어서 **마스터를 디스크에 굽는 길이 통째로**
막혀 있었다.  아래가 전부 import 실패였다.

```
build_snatcher_0_4_5_11_reviewed · 0_4_5_12_reviewed_dictionary
build_snatcher_ko_0_4_5_9_collection · _signtest · 0_4_5_10_dialogue_hunt
```

`0.4.6.4x` 체인은 Track02 를 기준판에서 **물려받기만** 한다
(`0.4.6.47` 에 "Track02 는 0.4.6.42 와 바이트 동일" 감사가 있다).
실제로 `0.4.6.22`~`0.4.6.48` Track02 해시가 전부 같다 (08-30 12:52).
**즉 번역을 아무리 해도 디스크에 안 들어가고 있었다.**

소유자가 환경 A에서 가져와 복구했다 (`FROM_ENV_A_2026-09-01/`).

```
extraction/patch/static/build_snatcher_ko_0_4_5_8.py     ★ 이 한 파일이 전부였다
build/work/0.4.6.13-reviewed/translation/                옛 번역 스냅샷 113 파일
```

### 새 빌더

```
tools/build_snatcher_0_4_6_61_dictionary_key_vram.py
    1  마스터 -> 디스크        EXPERIMENT/0.4.6.61-reviewed-dictionary-unpatched
    2  헬퍼 인터페이스 preload  0.4.6.61-reviewed-dictionary
    3  상주부 0.8.5 + key-VRAM  0.4.6.61-dictionary-key-vram

    python tools/build_snatcher_0_4_6_61_dictionary_key_vram.py       전체
    python tools/build_snatcher_0_4_6_61_dictionary_key_vram.py 1     1 단계만
```

★ 번역 입력을 **스튜디오(`snatcher_tool/translation`)에서 직접** 읽는다.
옛 체인이 보던 `build/work/0.4.6.13-reviewed/translation` 스냅샷이 낡는 것이
애초에 문제의 절반이었다.

⚠ 각 단계의 `main()` 이 제 argparse 를 돌리므로 단계 인자는 `sys.argv` 에서
비우고 넘긴다 (안 그러면 `unrecognized arguments` 로 죽는다).

---

## 2. ★ 지금 빌드를 막는 것 -- 버킷 508

```
버킷 508    80 개 / 한도 77 개      3 개 초과
```

```
버킷 = 원문 바이트합의 하위 10 비트 (hash10)
버킷 하나 = 704 B = 레코드 77 개 (레코드 9 B + 헤더 8 B)
704 는 우리가 빌리는 $5B80 슬롯 크기다 -- 못 늘린다
```

508 에는 **2 글자(4 바이트) 원문이 82 개 중 75 개** 몰려 있다.  4 바이트 원문은
바이트합이 최대 1020 이라 **BUCKET_COUNT 를 2048 로 늘려도 같은 칸에 간다.**

```
A  지금  버킷 508 에서 3 줄 예외처리
        목록: snatcher_tool/translation/bucket508_20260901.tsv  (82 행)
        뿌리 9 · {EMPTY} 33 · 나머지 40
B  근본  해시에 길이를 섞는다  (sum + len*K) & 0x3FF
        엔진(65C02) + 빌더 + 조회표를 같이 고치고 회귀 재실행
```

---

## 3. ★ 조용히 통일되는 머리 줄 33 개

`normalize_reviewed_root_conflicts` 가 레코드 **첫 줄** 중 원문이 같은 것들을
**먼저 나온 번역 하나로 갈아치운다.**  경고가 없다 -- `normalized_root_conflicts`
가 매니페스트에 숫자로만 남는다.

```
목록  snatcher_tool/translation/silent_unify_33_20260901.tsv
도구  python tools/report_root_normalization.py --tsv
```

### 왜 그러나

런타임 키가 `(state, 원문 바이트)` 뿐이다.  주소도 장면도 화자도 안 본다.
그리고 사슬이 끊기는 자리가 둘이다.

```python
for text_key in order:
    state = 0                                     # ① 레코드가 바뀌면 끊긴다
        row_page = (row.line_no - 1) // PAGE_LINES   # PAGE_LINES = 3
        if page is not None and row_page != page:
            state = 0                             # ② 페이지가 넘어가도 끊긴다
```

꼬리 조각이 잘 나오는 것은 **사슬(자식 state)에 걸려 문맥이 있기 때문**이다.
문제가 되는 것은 뿌리로 떨어진 것뿐이다.

```
①에 걸린 것   が・・・(R04453:1 · R04570:1) · す。(R04410:1)
              origin=OBSERVED_PAGE 가 앞 페이지 꼬리를 **새 레코드 1 번 줄**로
              잘라놨다.  앞 레코드와 합치면 사슬을 탄다 -- 데이터로 고칠 수 있다
②에 걸린 것   R10432:10 · R10452:16 (사전 문단 중간이 페이지 첫 줄)
              구조다.  3 줄 페이지 경계는 못 옮긴다
```

### 33 개 성격별

```
표기만 다름    7   전각공백 · … vs ... · 띄어쓰기
              ⚠ 사전 항목 앞 전각공백은 들여쓰기다.  지우면 구조가 깨진다
말투 통일     12   어떤가?/어때? · 알겠어/알겠어요 · 틀림없어/틀림없다
★ 뜻이 달라짐  5   が・・・ 「{EMPTY}」 -> 「게 만들 예정이었다.」
                   す。   「일으킨다.」 -> 「일본이 아니기도 하죠....」
                   しかし、「그런 곳을 들어본 적이…」 -> 「하지만,」
                   まあ、 「뭐...」 -> 「뭐, 그녀의 사진이나」
                   メタル、「메탈,」 -> 「메탈, 그런 식으로 자꾸」
문장이 잘림    4   …좋아, JUNKER 카드를 -> 「…좋아,」  등
```

⚠ **마스터에 일괄 쓰기 자동화를 만들지 말 것.**  예전에 오타 자동수정이
2 줄짜리 문장을 전부 평탄화한 적이 있다.  오늘 만든 도구는 **전부 읽기 전용**이다.

---

## 4. 오늘 만든 도구

```
tools/check_master_conflicts.py       ★ 빌드 없이 판정만.  10 분 빌드를 안 돌려도 된다
                                        trie 충돌 · 조용한 통일 · 버킷 넘침
tools/report_root_normalization.py    덮이는 머리 줄 목록
tools/build_snatcher_0_4_6_61_dictionary_key_vram.py   3 단계 드라이버
tools/refresh_runtime_static_index.py 수집기 MISSONLY 대장 갱신 (오전)
tools/dis6280.py · audit_bios_free_space.py · patch_bios_cpu_cache.py   (오전)
```

### 빌더에 붙인 환경변수 (전부 기본 꺼짐)

```
SNATCHER_TRIE_REPORT=1     첫 충돌에서 안 죽고 전부 모아 보고
SNATCHER_BUCKET_REPORT=1   버킷 사용량 분포 + 넘친 버킷 내용
```

---

## 5. 스튜디오 (`_publish` 갱신 · 14:51)

### CD-DA 탭 재배치 (소유자 요청)

```
자막 조각 목록   -> 오른쪽 (기존 한국어 입력칸 자리)
한국어 입력칸    -> 화면에서 삭제.  조각 목록의 `한국어 자막` 칸에서 바로 고친다
싱크 타임라인    -> 맨 아래 전체폭 (Bottom·82px 고정 -> Fill · 아래 32%)
```

⚠ `cddaKoBox` **필드는 남겼다.**  `ApplyCddaCurrent`·`MoveCddaPart`·
`SelectCddaPartRow` 가 아직 그것을 거쳐 값을 옮긴다.  대신 `UpdateCddaPart` 가
그리드 편집을 그 칸에 되비춘다 -- 안 그러면 "적용" 이 낡은 값으로 덮어쓴다.

### 검토 열 (음성 자막 · CD-DA 자막)

```
review 열 + [검토 O] [검토 해제] · 다중 선택 · 요약에 「검토 O N」
규약은 대사·UI 탭과 같다: "O" 만 출하
```

```bash
python tools/build_subtitle_pack.py --reviewed-only
# 또는 SNATCHER_SUBTITLE_REVIEWED_ONLY=1
```

### ⚠ 겸사겸사 고친 데이터 손실 버그

`build_voice_keys.py` 가 **고정 열 목록으로 `voice_subtitles.tsv` 를 덮어쓴다**(318 행).
그 목록에 `pos` 가 빠져 있어서 **돌릴 때마다 자막 세로 자리가 날아가고 있었다.**
`pos` 와 `review` 를 둘 다 넣었다.

---

## 6. 수집기 (다른 세션이 만듦 · 15:04 확인)

```
snatcher_tool/mesen/RUN_1_VOICE_0_1_5.lua            -> COLLECT_VOICE_KEYS_AUDIO_0_1_5
snatcher_tool/mesen/RUN_2_VOICE_AND_VRAM_MAP_0_4.lua -> 0.5.47-vram-key-map-0.4 + 0.1.5
snatcher_tool/mesen/RUN_3_VRAM_MAP_0_4.lua           -> 0.5.47-vram-key-map-0.4
```

15:04 실측 -- 경로·헤더 정상, 세 산출물이 14:46:28 에서 같이 멈춰 있었다
(Mesen 은 실행 중.  일시정지나 조용한 구간으로 보인다).

```
voice_key_events_raw_v014.tsv   148 KB · 841 행
vram_key_map3_...tsv             62 KB
vram_key_spans3_...tsv          188 KB
클립                            990 개 (최신 14:38)
```

⚠ **`lua/COLLECT_VOICE_KEYS_AUDIO_0_1_3.lua` 는 쓰지 말 것 (내가 만든 것).**
`writeAddress` + 모듈로 전방거리로 이어붙이는데, 그 방식은 틀렸다
(`snatcher-voice-clip-truncation` 기억: read 를 봐야 하고, 모듈로 전방거리는
+65,536 헛돈다).  `0.1.5` 가 **펼친 누적 전진량(accAdv)** 으로 제대로 한다.
0.1.3 은 지워도 된다.

---

## 7. 다음 작업

```
[ ] ★ 버킷 508 에서 3 줄 고르기      bucket508_20260901.tsv
[ ] 0.4.6.61 빌드                   위가 풀리면 세 단계 자동
[ ] 조용한 통일 33 줄 손보기         silent_unify_33_20260901.tsv
      뜻이 달라지는 5 건부터.  ①에 걸린 3 건은 앞 레코드와 합치면 풀린다
[ ] 34D0 / 3B70 주소 분리           도죠 인계서가 지적한 것.  엔진 키 한계라 미해결
[ ] 671 B 이식 정식 통합             0.4.6.60 은 BIOS 만.  디스크와 합친 풀빌드
```

### 확인만 하려면 (빌드 안 돌리고)

```bash
python tools/check_master_conflicts.py
```
