# Snatcher native subtitle baseline — 2026-08-30

상태: **Lua 기준 동작은 동결, 네이티브 이전 착수.**

## 1. 사용자 실기 통과 기준

- `0.4.6.22-dictionary-key-vram` + `lua/SUB/0.4.93-hq-key-vram.lua`로 본부
  재생 검증 통과.
- 같은 계열로 엔딩까지 진행 완료. ADPCM 감지·표시·복원·진행성의 1차 전수
  기준판으로 삼는다.
- 국장실 뒷화면/큰 떨림 원인은 resident `$7F4A`의 `SEI` 창. 현재 빌드는
  `$7F4A: 78 -> EA` 한 바이트 수정판이며 사용자가 증상 소실을 확인했다.
- CD-DA Track 17 POC는 하단 중앙 `VRAM $7900, y=192, center=128`, 팔레트 15
  흰 본체/검은 외곽선으로 표시·색·한국어 UI 보존을 확인했다.
- CD-DA POC는 AC `$1C0000`을 읽거나 쓰지 않는다. 그곳은 현재 번역 lookup과
  자막 팩 예약 구역이므로 옛 POC 페이로드를 쓰면 한국어 UI가 일본어로
  되돌아간다.

## 2. 동결 이미지

| 파일 | bytes | SHA-256 |
|---|---:|---|
| `build/patch/0.4.6.22-dictionary-key-vram/Snatcher CD-ROMantic (Japan) [KO].cue` | 2,512 | `934455F721F0869A88FE7A7B5E4F3210E19B91E5A74A50D1F377315A2A22359F` |
| Track 02 `[KO].bin` | 80,779,440 | `047DB53CB5A0DA20AFFEC044BE0380E4BDECADEE05EB76FDBC6AE9063934C8D3` |
| Track 24 `[KO].bin` | 122,021,760 | `7A29AF60A408D10708F642193E6F90FB325AF6E6F12D9637F817D37C0205B29A` |
| `Syscard3_galmuri_0.4.6.21-reviewed-dictionary.pce` | 262,144 | `2FAFE65AD0EAB19574CA784DB379EA8F17C886C22B7CFC28C73D1A3C0ED0EAA2` |
| `lua/SUB/0.4.93-hq-key-vram.lua` | 2,732 | `01136EBD4B1ACD0A7E95BF276292C37D0912ACD1B90110DBA7F1E54880B918A4` |
| `lua/CD-DA/CDDA_SUBTITLE_POC_0.1.3.lua` | 20,839 | `4BEE144B479166C437BDEB99A95B1AAB0B955C538BBDBCE9A9E8037CDFC6A9C3` |
| `subtitle_pack.bin` | 183,918 | `8F20AF388621E4C49ED868B53C95C982B139F77BB875A45CE53FAC93A365289B` |
| resident 0.8.5 | 151 | `CFB0C9E8E3A7D46A4D3A0C754F1D1A27F47CA3F61F502E5A527CA75CF7FBC2C4` |
| dynamic VRAM helper | 448 | `5A218EE1949079F0676813D33B575D1A950B7CDD8F75045907125A819FAA94B7` |

## 3. 네이티브 CD-DA 계약

기존 실측/정적 분석에서 이미 확보된 주소를 다시 출발점으로 쓴다.

```text
$60E4  JSR CD_PLAY($E012)      실제 재생 호출자, MPR3=$6A
$26F9  트랙 번호               driver가 bit7 제거 후 1-based로 변환
$60F6  재생 상태 wrapper       CD_STAT + CD_SUBQ
$6119  JSR CD_SUBQ($E01E)      직후 $20A0-$20A9에 10 B 결과
$2202 -> $40A4                 IRQ1/VSync, MPR2=$68 상주
```

CD_SUBQ 결과는 지속 상태가 아니다. `$6119` 직후에만 유효하다. 네이티브 POC는
Track 17 시작 훅과 CD_SUBQ의 BCD M:S:F를 사용하고, 중간 프레임은 VSync로
보간한 뒤 주기적으로 SUBQ에 재동기한다.

## 4. 메모리/출력 불변조건

- AC 자막 예약: `$1C0000-$1FFFFF`.
- 현재 번역 데이터와 충돌하므로 POC가 AC `$1C0000`에 임의 엔진을 쓰면 안 된다.
- resident 진입: `$7F49`; `$7F4A`는 `NOP` 유지.
- 자막 실행 RAM 예약: `$5C40-$5E1F`. 기존 CD-DA Lua POC는 `$5C40` stub,
  `$5D00` SATB list를 사용했으나 네이티브 배치 전에 생존 범위를 다시 감사한다.
- 자막 VRAM 블록은 19셀 × `$40` word = 1,216 word.
- BAT/SATB 본체 `$0000-$1FFF` 제외, `$100` word 정렬, 8K pattern bank 경계
  통과 금지.
- 미등록 안전 키는 개발판에서 표시하지 않는다. 임의 기본 위치로 출력하지 않는다.

## 5. 안전 위치 출하 게이트

`tools/verify_subtitle_safe_positions.py`가 `subtitle_pack.bin`을 직접 읽어 실제
출하 대상과 안전 지도 사이의 커버리지를 센다.

```text
개발:  python tools/verify_subtitle_safe_positions.py
출하:  python tools/verify_subtitle_safe_positions.py --release
```

2026-08-30 착수 시점:

```text
ADPCM  50 / 902 runtime keys verified, 852 missing
CD-DA   0 / 698 packed LBA windows verified, 698 missing
```

현재 `subtitle_pack.bin`은 Studio의 CD-DA 트랙 단위 초기화 전 산출물이라 698개
옛 LBA 창을 아직 담고 있다. 새 Studio 데이터로 팩을 다시 만들기 전까지 이 숫자는
기준판 관찰값일 뿐이다. `--release`는 현재 의도대로 실패한다.

보고서:

- `build/cutscene_subs/subtitle_safe_coverage.json`
- `build/cutscene_subs/subtitle_safe_missing.tsv`

최종 디스크 빌더는 반드시 이 검사를 `--release`로 통과한 뒤에만 CUE를 방출한다.

## 6. 병행 수집

사용자는 `snatcher_tool/mesen/0.5.25-adpcm-cdda-vram-map.lua`로 수집한다.

- ADPCM: 팩의 902키만 음성 시작~끝 누적.
- CD-DA: `cdda_segments.tsv`의 408조각을 `[lba_from,lba_to)` 단위로 누적.
- CD-DA를 트랙 전체로 묶지 않는다.
- 자막 렌더러 없이 STRICT BAT로 실행한다.

네이티브 개발은 수집 완료를 기다리지 않는다. 고정 Track 17 자료로 엔진을 만들고,
미수집 키는 fail-closed로 건너뛴다. 출하만 100% 커버리지에서 열린다.

### 6.1 수집 중간 점검 — 2026-08-30 14:47 세션

현재 실행 중인 세션의 실제 TSV 내용을 읽어 점검했다. Mesen이 파일을 열고 있는 동안
탐색기의 파일 크기가 `0 B`로 보일 수 있지만 기록 실패가 아니다.

```text
vram_key_map2_20260830_144739.tsv       ADPCM 48관찰 / 31고유 키
vram_key_spans2_20260830_144739.tsv     장구간 span 373행 / 31키 전부 연결
cdda_vram_map_20260830_144739.tsv       CD-DA 3관찰 / 1고유 조각 c20_001
cdda_vram_spans_20260830_144739.tsv     27행 = 9 span x 3관찰
```

- 네 파일 모두 열 수 있고 마지막 행의 열 수가 완전하다. 잘린 행과 형식 오류는 0건이다.
- ADPCM map의 `free_spans` 합 382와 spans 파일 373행의 차이 9는 정상이다. map은 모든
  자유 구간을 세지만 spans 파일은 설계대로 `ALIGN=32 word` 미만의 짧은 구간을 버린다.
- CD-DA `c20_001`은 세 번 재생되어 같은 관찰이 3개 쌓였다. 각 관찰은 754프레임,
  자유 span 9개, 후보 base 399개로 일치하므로 중복 손상이 아니라 반복 재생 표본이다.
- 행은 음성/조각이 끝나는 `finishVoice()`에서 flush된다. 재생 도중인 마지막 표본이 아직
  파일에 없더라도 정상이며, 완료된 51관찰은 이미 디스크에 안전하게 기록돼 있다.

### 6.2 ★ 수집 중 발견 — CD-DA 수집 대상과 채점 대상이 다르다 (2026-08-30)

수집이 도는 동안 팩과 세그먼트를 읽기 전용으로 대조했다
(`verify_subtitle_safe_positions.py` 는 §5 가 인용한 착수 시점 리포트를 덮어쓰므로 쓰지 않았다).

```text
pack 의 CD-DA 창        698
cdda_segments.tsv       408
★ 정확 일치              173
  pack 에만 있는 창      525
  seg  에만 있는 창      235
```

채점 방식이 문제다. `verify_subtitle_safe_positions.py` 의 CD-DA 커버리지는
`(lba_from, lba_to)` **정확 일치 집합 멤버십**이다. 포함도 겹침도 아니다.
경계가 1 이라도 다르면 근처여도 miss 다.

따라서 현재 상태에서 CD-DA 수집을 계속하면:

- 수집 중인 408 조각 중 **235 개는 어떤 경우에도 채점되지 않는다**
- 게이트가 요구하는 698 창 중 **525 개는 세그먼트 목록에 없어 영영 못 채운다**

즉 §5 의 `CD-DA 0/698` 은 수집으로 좁혀지지 않는다. **팩을 먼저 다시 만들어야 한다.**

`tools/build_subtitle_pack.py` 는 `cdda_segments.tsv` 를 입력으로 쓰고
(`SEGMENTS = OUT_DIR / "cdda_segments.tsv"`), 자체 docstring 이 "구간 407 개" 라고
적고 있다. **빌더는 이미 새 Studio 데이터 기준이고 디스크의 팩만 옛 산출물이다.**

⚠ 그러나 `subtitle_pack.bin` 은 §2 동결 해시 등재본(`8F20AF38...289B`)이다.
다시 만들면 동결 이미지가 바뀌고 디스크 재빌드가 따라온다. 착수 판단이 필요하므로
이 세션에서는 **실행하지 않았고 기록만 남긴다.**

#### ADPCM 은 영향 없다 — 계속 수집해도 된다

ADPCM 커버리지는 6 B 런타임 **키**로 채점된다. 키는 내용 지문이므로 팩을 다시
만들어도 유지된다. §5 의 `ADPCM 50/902` 는 수집으로 정상적으로 좁혀진다.

#### ★ 정정 — CD-DA 수집도 **다시 안 해도 된다** (같은 날, 위 판단의 수정)

위에서 "CD-DA 는 재빌드 뒤에 다시" 라고 적었는데 **틀렸다.**

수집 TSV 는 `clip` 으로 태그되어 있다.

```text
key  track  clip  lba_from  lba_to  frames  marked  free_spans  base_count  first_base  bases
```

그리고 수집은 이미 **현재** `cdda_segments.tsv`(408 조각) 기준으로 돈다 (§6).
새 팩도 같은 파일에서 만들어진다.  어긋난 것은 수집이 아니라 **옛 팩 한쪽뿐**이다.

```text
옛 팩 698 창  <-> 수집 408 조각     173 만 일치   (지금)
새 팩 408 창  <-> 수집 408 조각     전부 일치     (팩 재빌드 후)
```

팩 재빌드는 **오프라인 빌드 한 번**이지 재측정이 아니다.  지금 걷는 데이터는 그대로 산다.

#### ⚠ 여기 있던 생산자 설명은 폐기됐다 -> §6.4 를 볼 것

이 자리에 `cdda_segments.tsv` 기준으로 만든 첫 판 설명이 있었다.  그 판은 clip 창을 내므로
part 가 2 개 이상인 clip 을 영영 못 맞춘다 (게이트 15/698).
**팩 기준으로 다시 썼다 -> §6.4 (70/698).**

| 소스 | 채점 키 | 팩 재빌드의 영향 | 지금 수집 |
|---|---|---|---|
| ADPCM | 6 B 런타임 키 (내용 지문) | 없음 | **계속 유효** |
| CD-DA | `(lba_from, lba_to)` 정확 일치 | 라벨만 바뀜.  clip 으로 재키잉 가능 | **계속 유효** |

---

### 6.3 ★★ 팩 재빌드 시도 — 실패.  막힌 곳은 도구가 아니라 **내용**이다 (2026-08-30)

§6.2 에서 "팩을 다시 만들면 408 창이 잡힌다" 고 적었다.  **틀렸다.**  실제로 돌렸다.

```text
동결본 백업 -> subtitle_pack.frozen_8F20AF38.bin / .json  (해시 확인)
python tools/build_subtitle_pack.py
  자막 팩 146,311 B
  ADPCM 색인 1950 조각 (902 음성)      <- 그대로
  CD-DA 색인      0 B · 0 개           <- ★ 408 이 아니라 0
-> 회귀이므로 즉시 복원.  해시 8F20AF38... 일치 확인
```

원인은 번역 원본이다.

```text
snatcher_tool/translation/cdda_subtitles.tsv    19 행 (트랙당 1 행) · ko_text 0/19
tools/reset_cdda_track_subtitles.py             옛 clip+part 표를 의도적으로 접었다
snatcher_tool/backups/cdda_subtitles_clip_parts_before_track_reset_20260830_131351.tsv
                                                649 행 · clip+part 키 (보관됨)
```

**CD-DA 한국어 번역이 아직 없다.**  그래서 구울 것이 없고, 0 개는 버그가 아니다.
동결 팩의 698 창은 재설정 **이전**의 번역에서 나온 것이다.

    -> 팩 재빌드는 빌드 작업이 아니라 **번역 작업 대기 상태**다.  사람 일이다.
    -> `--release` 게이트도 그때까지 열리지 않는다.

#### 그래서 §6.2 의 두 문장을 정정한다

    (X) "팩을 다시 만들면 새 팩 408 창 <-> 수집 408 조각 전부 일치"
    (O) 팩의 CD-DA 창은 `cdda_segments.tsv`(구간 나눔)가 아니라
        `cdda_subtitles.tsv`(번역)에서 나온다.  옛 표는 **clip 을 part 로 더 쪼갠**
        키였다 (649 행 -> 698 창).  지금은 비어 있다.

    (O) 여전히 참: **수집 데이터는 낭비가 아니다.**  관찰은 LBA 를 들고 있으므로
        창 경계가 나중에 무엇으로 정해지든 겹침으로 대응된다 (§6.4).

### 6.4 ✔ 생산자 도구 — 팩 기준으로 다시 씀 (`tools/build_cdda_runtime_safe_positions.py`)

처음 판은 `cdda_segments.tsv` 의 clip 창을 냈다.  게이트는 `(lba_from, lba_to)`
**정확 일치**로 채점하는데 팩 창은 part 단위라, part 가 2 개 이상인 clip 은 영영
안 맞았다 (39 개를 검증했는데 게이트는 15 개만 인정).

검증기 docstring 그대로 **팩이 authoritative** 다.  그래서 팩의 창을 먼저 읽고,
창마다 **그 구간과 겹치는 모든 관찰**을 모아 교집합을 낸다.  창 경계가 clip 이든
part 든 트랙이든 항상 정확히 일치한다.

```text
subtitle_pack.bin              창 목록 (authoritative)
dump/cdda_vram_spans_*.tsv     자유 구간
  -> 구간마다 19 글자 블록이 들어갈 base 를 편다
  -> 창과 겹치는 관찰들 사이에서 **교집합** (fail-closed)
  -> 게이트의 `valid_base` 를 **import 해서** 거른다 (베끼지 않는다)
build/cutscene_subs/cdda_runtime_safe_positions.tsv
```

결과 (수집 진행 중):

```text
게이트 CD-DA   0/698 -> 15/698 (clip 기준, 틀린 판) -> **70/698** (팩 기준)
겹치는 관찰이 있는 창 70 == verified 70
```

**관찰이 하나라도 있는 창은 전부 답이 나온다.**  이제 커버리지는 도구가 아니라
수집량에만 달려 있다.

#### ★★ 그 과정에서 잡은 것 — `map` 의 `bases` 열은 24 개에서 잘린다

```text
cdda_vram_map_*.tsv   base_count 399 / 741 / 572 ... 인데 목록은 늘 24 개
                      게다가 그 24 개는 최저 주소들이라 전부 $2000 미만 = 규칙상 전멸
```

`bases` 만 보고 만들었으면 **"안전한 자리가 없다" 는 거짓 결론**이 났을 것이다.
`cdda_vram_spans_*.tsv` 는 구간을 통째로 담아 잘리지 않는다.

    -> **CD-DA 안전 위치의 진짜 입력은 spans 파일이다.  map 의 `bases` 는 미리보기다.**

교집합이 실제로 일하는 증거: `c22_001` 은 관찰 3 회를 거치니 후보가 **1 개**로
줄었다 (`c20_001` 은 3 회에 41 개).  한 번만 보고 정했으면 위험한 자리를 골랐다.

## 7. Track 17 네이티브 CD-DA 1단계 후보 (0.4.6.23)

2026-08-30에 Lua 없이 사슬을 닫기 위한 첫 고정 POC를 만들었다.

```text
build/patch/0.4.6.23-cdda17-native/
tools/build_subtitle_engine_cdda_track17_poc.py
tools/build_snatcher_0_4_6_23_cdda17_native.py
```

범위는 의도적으로 Track 17의 `c17_001` 두 줄뿐이다. 안전 위치 표에서 Track 17이
`verified`, `VRAM $7900`, `y=192`일 때만 빌드되며 다른 트랙으로 fallback하지 않는다.

```text
track raw $10 (= 재생 Track 17)
2188 f / 36.466 s   record AC $1C7E8A  "1991년 6월 6일 모스크바"
2435 f / 40.583 s   record AC $1C7EC0  "체르노톤 연구소, 의문의 대폭발"
2683 f / 44.716 s   표시 종료
```

renderer는 기존 `no lookup + overlay palette + VDC rearm` 602 B의 entry 14 B를
타이머 진입으로 바꾸고 꼬리 66 B를 더해 슬롯 `671/672 B`에 맞췄다. helper는 같은
448 B 코드에서 control block의 기본 VRAM 네 바이트만 `$7900`에 맞춘 것이다.

BIOS `$FEC4`의 이번 개발판 decision은 65/76 B다.

```text
idle    ($26F9 & $7F)==$10 and ($263C|$2638)!=0  -> state 1
active  ($263C|$2638)!=0                         -> state 2
end     ($263C|$2638)==0                         -> state 3 / VRAM restore
```

이 격리 POC에서는 ADPCM native 자동 시작을 끈다. ADPCM Lua와 같이 시험하지 않는다.
일반화 때 ADPCM/CD-DA 판정을 함께 담거나 지속 모드 바이트를 별도 안정 RAM에 둔다.

정적 검증:

- BIOS 변경 60 B, 전부 `$FEC4-$FF0F` 안. `$FF10` 부트 훅 이후 동일.
- Track 02 기준판과 byte-identical.
- Track 24 변경 섹터는 51878(helper), 51879(renderer)뿐.
- Track 24에서 다시 읽은 helper/renderer가 생성 바이너리와 byte-identical.

실기 절차는 후보 폴더의 `TEST_IN_MESEN.txt`를 따른다. Power Cycle 후 후보 BIOS와
CUE를 열고 **Lua를 하나도 로드하지 않는다.** 첫 판정은 36.46초의 첫 줄 표시다.

실기 결과: **FAIL — 36.46초와 40.59초 모두 자막 미표시.** 따라서 0.4.6.23은
출력 성공판이 아니라 정적 배치만 통과한 진단 기준판이다. 다음 분기는 읽기 전용
`lua/CD-DA/CDDA_NATIVE_TRACE_0.1.0.lua`로 `$600C->$601E->$7F49->$FEC4->renderer`
실행 사슬과 `$26F9/$263C/$2638/$7FDF`를 한 번에 측정한 뒤 정한다.

추적 결과(`cdda_native_trace_0_1_0_20260830_150726.tsv`, 3,724행):

- 오프닝 LBA `184016..188309` 동안 `$26F9=$11`. 0.4.6.23의 `$10` 비교가 틀렸다.
- `$600C/$601E/$7F49/$FEC4`는 각각 수천 회 실행됐지만 renderer entry는 0회다.
  따라서 적재·resident 호출 실패가 아니라 Track 비교에서 닫힌 것이 확정됐다.
- `$263C`와 `$2638`은 각각 한 프레임 `01`이 되는 시작 pulse이며 지속 재생 상태가
  아니다. 0.4.6.23의 active 유지 조건으로도 쓸 수 없다.

후속 `0.4.6.24-cdda17-trackfix`는 시작 조건을 `track=$11 + pulse`로 고치고,
active 상태는 renderer의 16-bit elapsed `$5E1A`가 2,683프레임에 이를 때까지
유지한 뒤 state 3 복원을 요청한다.

빌드 후보:

```text
build/patch/0.4.6.24-cdda17-trackfix/
BIOS SHA-256 9EBC076086F976C68A4AF815ADE4C34E58896CDF987EFE69EBBD270A3785A60E
decision     73/76 B
```

정적 재검증에서 BIOS decision에 `CMP #$11`, elapsed high `$5E1B/#$0A`,
elapsed low `$5E1A/#$7B`가 모두 존재한다. Track 24는 0.4.6.23과 byte-identical,
Track 02는 동결 0.4.6.22와 byte-identical이다.

실기 결과: **OUTPUT PASS.** 사용자 확인으로 Lua 없이 오프닝 Track 17의 한국어
CD-DA 자막이 화면에 표시됐다. 이로써 아래 최초 네이티브 사슬이 닫혔다.

```text
$26F9=$11 + start pulse
  -> BIOS $FEC4 state 1
  -> resident helper/renderer 적재
  -> renderer 자체 elapsed
  -> Track 17 한국어 자막 출력
```

아직 별도 확인할 항목은 두 번째 줄 전환, 44.72초 소거·VRAM 복원, 이후 게임 진행
이상 유무다. 하지만 "Lua 없이 CD-DA 자막 출력" 자체는 0.4.6.24에서 확정 성공이다.

## 8. 별도 UI 그림 밀림 — 동결

`lua/SUB/0.5.24-ui-scroll-trace.lua`로 국장실 UI 호출을 12,401프레임/표식 22회
측정했다. 정상 RCR 작성선 32/160/250이 일부 표본에서 38~39/166/254~255로,
마지막 BYR 복원이 262까지 늦어지는 부하 흔적은 확인했다. 다만 간헐적이고 진행·
데이터·영구 그래픽 손상이 없는 비차단 현상이므로 이번 출하의 blocker로 잡지 않는다.
로그는 `dump/ui_scroll_trace_0_5_24_20260830_144329.tsv`에 보존한다.

## 9. 최종 네이티브 구조 — 감지기 2개, 공용 제어부 1개

ADPCM용 renderer/helper/controller를 별도로 복제하지 않는다. CD-DA 0.4.6.24에서
실기 통과한 출력 사슬을 공용 코어로 삼고, 앞단 감지기만 두 개 둔다.

```text
CD-DA detector ─┐
                ├─> common subtitle controller ─> renderer/helper ─> SATB/VRAM
ADPCM detector ─┘
```

입력별 차이는 여기까지다.

| 소스 | 감지·색인 | 시간/종료 기준 |
|---|---|---|
| CD-DA | `$26F9` 트랙 + 시작 pulse, 이후 트랙 자막표 | renderer elapsed, 일반화 뒤 SUBQ 재동기 |
| ADPCM | finish/rate/ADPCM RAM 지문으로 6 B 키 생성, 팩 lookup | 조각 start와 ADPCM 재생 종료 |

그 뒤에는 두 소스 모두 같은 공용 명령으로 바꾼다.

```text
source          NONE / CDDA / ADPCM
record pointer  현재 자막 레코드
safe VRAM base  키/트랙별 검증 위치
part command    start / switch / end
```

### 9.1 ADPCM 네이티브 이식 범위

검증판 `lua/SUB/0.4.93-hq-key-vram.lua`와 그 아래 `0.4.31`이 맡던 제어부만
네이티브로 옮긴다.

1. ADPCM 재생 시점에 emulator 전용 `emu.getState()` 없이 6 B 키를 만든다.
2. 키로 자막 레코드와 수집 완료된 안전 VRAM base를 찾는다.
3. helper control block과 renderer selector에 record/base를 건다.
4. 여러 조각이면 start frame에 맞춰 selector를 전환한다.
5. 미등록 키·미검증 위치는 state 1을 열지 않고 fail-closed한다.

글자 렌더링, VRAM save/restore, SATB push, fragment wipe, resident 호출 사슬과
팩/엔진 선적재는 이미 네이티브 자산이므로 다시 만들지 않는다. 즉 ADPCM 작업은
정확히 **CD-DA 제어부의 ADPCM 감지판**이며 renderer 전체 재개발이 아니다.

### 9.1.1 ★ ADPCM 키의 네이티브 출처 — 실측으로 확정 (0.5.28 · 2026-08-30)

> ⚠ **이 절의 계획은 §12 로 대체됐다.**
> 콘솔에서 6 B 키를 만들 필요가 없다. 음성의 **시작 LBA 3 B** 가
> SCSI CDB(`$224D-$224F`)에 있고, 그것이 902 음성을 갈라낸다(고유 1053/충돌 2).
> ADPCM RAM 3표본 샘플링과 그 재생 교란 위험은 폐기됐다.
> 또한 이 절의 "finish 하위는 늘 $00 (9/9)" 는 팩 902 키 중 160 개(17.7%)에서
> 틀린다 -> §12.5.

§9.1 의 다섯 항목 중 유일하게 어려웠던 1 번("`emu.getState()` 없이 6 B 키")의
답이 나왔다.  `lua/SUB/0.5.28-adpcm-setup-site.lua`, 음성 9 개.

#### 측정 1 — `finish` 는 게임이 직접 쓰는 값이다

```text
VOICE #1  finish $6000  <-  $1809 <- $60
VOICE #2  finish $A000  <-  $1809 <- $A0
VOICE #3  finish $6800  <-  $1809 <- $68
VOICE #5  finish $D000  <-  $1809 <- $D0
VOICE #8  finish $B800  <-  $1809 <- $B8
```

9/9 예외 없음.  그리고 **`finish` 하위 바이트는 항상 `$00`** 이다 -- 그래서 모든
런타임 키가 `00` 으로 시작한다.

#### 측정 2 — 셋업 루틴 전문 (디스어셈)

포트 writer PC 를 덤프해 역어셈했다.  Mesen 보고 PC 는 **명령 주소 + 3** 이다.

```asm
$F5D8  LDA $FA / STA $22A8        \ 첫 주소 쌍 (하위/상위)
$F5DD  LDA $FB / STA $22A9        /
$F5E2  LDA $F8 / STA $22A6        ★ finish 하위
$F5E7  LDA $F9 / STA $22A7        ★ finish 상위
$F5EC  LDA $FF / CMP #$10 / BCS $F61E
$F5F2  STA $22AA                  ★ rate
$F5F5  LDX $22A8 / LDY $22A9 / JSR $F729 / JSR $F6FF
$F601  LDX $22A6 / LDY $22A7 / JSR $F729 / JSR $F71E    읽기 포인터 확정
$F60D  LDA $22AA / STA $180E                            rate
$F613  LDA #$08 / TSB $1802
$F618  LDA #$60 / STA $180D                             재생 시작
$F61D  CLA / RTS

$F729  STX $1808 / STY $1809 / RTS        set_adpcm_addr(X=lo, Y=hi)   7 B
$F71E  LDA #$10 / TSB $180D 
       LDA #$10 / TRB $180D / RTS         읽기 포인터 래치
$F6FF  LDA #$08 / TSB $180D
       LDA $180A                          더미 읽기
       LDA #$05 / DEC A / BNE -            딜레이
       LDA #$08 / BRA $F725 (TRB $180D)
```

#### 결론 — 키 3 B 는 **평범한 RAM 변수**다

```text
key[0] = $22A6      finish 하위 (항상 $00)
key[1] = $22A7      finish 상위
key[2] = $22AA      rate
```

포트를 가로챌 필요가 없다.  그리고 이 주소들은 **이미 쓰고 있던 것**이다 --
`0.4.31` 이 네이티브 게이트를 승인시키려고 `$22A6/$22A7/$22AA` 를 위조해 써넣는다
(`TARGET_END & 0xFF` / `TARGET_END >> 8` / `TARGET_RATE`).
즉 네이티브 게이트는 처음부터 올바른 값에 물려 있었고 Lua 가 그것을 흉내내고 있었다.

#### 남은 것 — key[3..5] 의 ADPCM RAM 3 곳

```text
key[3] = APCM[finish/4]   key[4] = APCM[finish/2]   key[5] = APCM[finish*5/8]
```

**버릴 수 없다.**  VOICE #4 와 #7 은 둘 다 `finish $5800` 인데 키가 다르다
(`00580E298008` vs `00580E3980A9`).  같은 길이의 다른 음성을 이 3 바이트가 가른다.

#### 제안하는 훅 위치 — `$F5F2` 와 `$F5F5` 사이

`$F5E7` 시점에 `$22A6/$22A7` 이 이미 확정되고, `$F5F2` 에서 `$22AA` 까지 갖춰진다.
그런데 **게임이 ADPCM 포인터를 건드리는 것은 `$F5F5` 부터**다.

    -> 그 사이에 샘플링하면 우리가 포인터를 복원할 필요가 없다.
       게임이 그 **뒤에** 두 포인터를 모두 자기가 세운다.

샘플링 자체는 게임의 관용구를 그대로 쓴다: `set_adpcm_addr` (`$F729`) +
읽기 래치 + `LDA $180A`.  ADPCM 데이터는 이미 DMA 로 올라와 있다.

⚠ 미확인 -- `$180D` 의 bit `$08` / `$10` 이 각각 읽기/쓰기 포인터 중 무엇인지는
확정하지 않았다.  게임의 두 호출부(`$F6FF` / `$F71E`)를 그대로 흉내내는 것으로
충분하므로 의미 규명 없이 진행할 수 있다.  다만 **샘플링이 재생을 교란하지 않는지는
실기로 확인해야 한다** (읽기 전용 프로브로 A/B 가능).

---

### 9.2 동시 재생 소유권

스내처는 CD-DA BGM 위에 ADPCM 음성이 겹칠 수 있으므로 공용 코어에는 반드시
`owner = NONE/CDDA/ADPCM` 상태가 있어야 한다. 한 소스가 표시 중일 때 다른 소스가
들어오면 무조건 덮어쓰지 않고 명시적 우선순위 또는 무시 규칙을 적용한다.

우선순위는 아직 확정하지 않는다. 실제 자막 대상 CD-DA와 자막 대상 ADPCM의 중첩을
팩/전수 로그에서 감사한 뒤 `ADPCM 우선`, `기존 owner 유지`, 또는 필요 시 2채널 중
하나를 선택한다. 겹침이 없더라도 owner 필드는 복원 중 이중 명령을 막기 위해 유지한다.

## 10. 별도 번역 충돌 메모

동일 원문 `<원문 6자>`가 세 문맥에서 서로 다른 뜻으로 쓰이는 문제는 별도 문서로
분리했다. 전역 치환하지 말고 overlay 주소별 override로 처리한다.

- `docs/handoff/SNATCHER_DOUZO_CONTEXT_OVERRIDES_2026-08-30.md`

## 11. ★ BIOS decision 예산 감사와 재배치 시안 (2026-08-30)

ADPCM 감지기를 넣을 자리를 찾다가 BIOS `$FEC4` 창을 실물로 떴다.
대상은 `build/patch/0.4.6.24-cdda17-trackfix/Syscard3_galmuri_0.4.6.24-cdda17-trackfix.pce`.

### 11.1 현재 decision 해부 (73/76 B)

```asm
$FEC4  LDA $7FDF                       state 읽기
$FEC7  CMP #$FF / BEQ reset
$FECB  CMP #$FE / BEQ idle
$FECF  CMP #$02 / BEQ active
$FED3  CMP #$00 / BNE ret
$FED7  LDA $26F9 / AND #$7F / CMP #$11 / BNE idle      CD-DA 트랙 감지
$FEE0  LDA $263C / ORA $2638 / BEQ idle                시작 pulse
$FEE8  LDA #$01 / STA $7FDF / RTS                      -> state 1
active:
$FEEE  LDA $5E1B / CMP #$0A / BCC still / BNE finish   ─┐
$FEF7  LDA $5E1A / CMP #$7B / BCC still                 │ 25 B
finish:$FEFE LDA #$03 / STA $7FDF / RTS                 │
still: $FF04 LDA #$02 / RTS                            ─┘
reset: $FF07 STZ $7FDF
idle:  $FF0A LDA #$00
ret:   $FF0C RTS
       $FF0D EA EA EA                                   남은 3 B
```

`$FF10` 부터는 부트 훅 실코드(~150 B) -> 데이터 표 -> BIOS 점프 테이블
(`$FFD8-$FFF3`) -> **CPU 벡터(`$FFF4-$FFFF`)**.  뒤로는 못 늘린다.

⚠ 다만 "BIOS 에 여유가 없다" 는 **과장이었다.**  확인한 것은 마지막 8 KB 뱅크의
`$FEC4-$FFFF` 뿐이다.  262,144 B 의 나머지는 조사하지 않았다.

### 11.2 ★ 종료 판정은 Track 17 전용 하드코딩이다 -- 어차피 빼야 한다

`active` 분기 25 B 는 `$5E1A/$5E1B` (renderer 의 16-bit elapsed) 를
**2,683 프레임**과 비교하는 코드다.  그 숫자는 Track 17 오프닝 한 곡의 길이다.

    -> ADPCM 은 물론이고 **다른 CD-DA 트랙 하나만 늘어도 못 쓴다.**
    -> 자리를 회수하려고 옮기는 것이 아니라, 일반화하려면 나가야 하는 코드다.

engine 이 스스로 `$7FDF <- 3` 을 쓰면 `active` 는 `LDA #$02 / RTS` 3 B 로 준다.

```text
회수 22 B   ->  decision 여유 3 B -> 25 B
```

engine 에서 `$7FDF` 접근은 보장된다.  engine 은 resident 가 `JSR $5B83` 로 부르므로
그 순간 MPR3 에 resident 뱅크가 반드시 걸려 있다.

### 11.3 재배치 시안 — 검증 3건 전부 통과

```text
BIOS $FEC4    active 25 B -> 3 B                여유 25 B
engine        671 -> 693 B (종료 판정 흡수)
슬롯          671 -> 704 B (ENGINE_BYTES 예약값 그대로)
상주부        copy_renderer tail 159 -> 192
```

**검증 1 — 상주부 코드 크기 불변.**  `copy_fixed` 는 `divmod(size,256)` 구조다.

```text
페이지 루프 11 B x full  +  꼬리 루프 13 B  +  RTS 1 B
671 -> full=2, tail=159  ->  2x11 + 13 + 1 = 36 B
704 -> full=2, tail=192  ->  2x11 + 13 + 1 = 36 B      동일
```

바뀌는 것은 `CPX #tail` 즉치값 하나뿐이다.  **상주부 151/151 B 를 안 건드린다.**

**검증 2 — AC CPU 캐시 백업이 들어간다.**

```text
AC_CPU_CACHE_BACKUP  $1F0E00 + 704 = $1F10C0
AC_SATB_BACKUP       $1F1100                     여유 64 B
```

**검증 3 — AC 뒤쪽이 비어 있다.**  저장소 전체(`tools/*.py` · `lua/**`)의 AC 주소
상수를 훑었다.

```text
$1C0000 $1C04F0 $1C0500 $1C0700 $1EF000 $1F0000 $1F03F0
$1F0400 $1F0E00 $1F1100 $1F1400 $1F1C00 $1F1F00
```

최대가 `$1F1F00` 이다.  `$1F1F00 + 704 = $1F21C0` 이고 예약은 `$1FFFFF` 까지이므로
뒤에 약 56 KB 가 남는다.

### 11.4 한자 슬롯 회수는 코드용으로는 부적합

"BIOS 에 자리가 없으면 기존 것을 뺏자" 는 발상은 옳고 **이미 그 기구가 있다** --
`tools/report_unused_kanji.py` 가 엔딩 완주 관측(고유 2,141 코드 / 37 만 호출)으로
회수 후보를 뽑고, 한글 글리프가 그렇게 들어가 있다.

그러나 **코드에는 못 쓴다.**  폰트는 BIOS 안 다른 뱅크에 있고, 게이트가 불릴 때
`MPR7 = $00` 이라 `$E000-$FFFF` 만 실행 가능하다.  폰트 뱅크의 코드를 실행하려면
먼저 매핑해야 하고 `TAM`/복원만으로 3 B 를 넘는다.  회수 대상도 폰트 표의
**슬롯 단위**라 연속된 큰 덩어리가 아니다.

남은 3 B 는 정확히 `JMP` 한 개다.  다만 뛸 곳이 항상 매핑돼 있어야 하는데,
관측 2 회에서 안정적인 것은 `MPR1=$F8` · `MPR2=$68` · `MPR7=$00` 뿐이다.

```text
0.5.20 관측   MPR  FF F8 68 6A 7C 7D 7F 00
0.5.28 관측   MPR  FF F8 68 69 85 86 87 00
```

표본 2 개로는 단정할 수 없다.  이 경로로 가려면 **MPR2 안정성 실측이 선행**한다.
11.3 만으로 트리거 둘이 들어가면 이 경로는 필요 없다.

### 11.5 ⚠ 먼저 걸릴 부채 — 렌더러 슬롯 1 B 초과

```text
engine_ac_timed_safe_lua_mini.bin   672 B   <- 슬롯 671 B
engine_cdda_track17_poc.bin         671 B   <- 671/671, 여유 0
```

렌더러 빌드 체인이 8/26 에 동결된 부채가 이것이다.  ADPCM 작업이 이 슬롯을
건드리는 순간 반드시 먼저 걸린다.  11.3 의 슬롯 704 B 확장이 이 부채도 같이 푼다.

### 11.6 ✔✔ 실행·검증 완료 — 0.4.6.25 로 22 B 회수 (**실기 PASS**)

§11.3 시안(슬롯 671 -> 704)은 **필요 없었다.**  타이머를 읽어보니 엔진이 이미
종료를 알고 있었다.

```asm
  TAX                        X = 0/1/2 구간 index
  LDA elapsed
  CMP threshold_low,X
  BCC desired
  INX                        문턱을 넘으면 다음 상태
desired:
  CPX #$00 / BEQ timer_ret
  CPX #$03 / BEQ timer_ret   ★ X == 3 이 곧 "끝났다".  전용 분기가 이미 있었다
```

그 자리에서 **X 가 이미 3** 이므로 상수를 안 실어도 된다.

```asm
  CPX #$03 / BEQ finish
finish:   STX $7FDF          ← 3 B.  LDA #$03 / STA (5 B) 가 아니다
timer_ret: RTS               ← 기존 것으로 떨어진다
```

엔진의 남는 패딩이 **정확히 3 B** 였다 (실코드 666 + elapsed 2 + pad 3 = 671).

#### 결과

```text
BIOS decision   73/76  ->  51/76      여유 3 -> 25 B
engine          671 B  ->  671 B      (timer tail 66 -> 69, pad 3 -> 0)
슬롯 · resident · 디스크 렌더러 길이 검사 · ADPCM 렌더러   전부 손 안 댐
Track 02        0.4.6.24 와 byte-identical
```

박힌 코드 (실물 BIOS 덤프):

```asm
$FEEE  A9 02 / 60          active -- 유지만 한다
$FEF1  9C DF 7F            reset
$FEF4  A9 00               idle
$FEF6  60                  ret
$FEF7  EA x25              ★ 회수한 여유
```

#### 산출물

```text
tools/build_subtitle_engine_cdda_state3_poc.py     엔진 (STX $7FDF 삽입)
tools/build_snatcher_0_4_6_25_cdda17_state3.py     디스크
build/patch/0.4.6.25-cdda17-state3/
BIOS  79548E608B975537E34F4EE5DE7D6B66C1DF6FBF5812472ACD9C05BE79047BA9
Tr24  BC87879C0C763FF01CB6218DEB0204009368C8A6D614EDB7D246BD3AA77DA374
```

0.4.6.24 의 산출물은 덮지 않았다 (엔진 출력 이름이 `engine_cdda_state3_poc.bin` 로 다르다).

#### ✔ 실기 결과 — **PASS** (2026-08-30, 사용자 확인)

오프닝 Track 17 에서 **자막이 정상적으로 사라졌다.**  엔진의 `STX $7FDF` 가 실제로
불린다는 뜻이고, 따라서 **회수한 25 B 는 진짜로 쓸 수 있는 자리다.**

    -> §11.7 의 ADPCM 트리거(19 B)를 여기에 넣을 수 있다.
    -> 0.4.6.24 로 되돌아갈 이유가 없어졌다.

아래는 판정 전에 적어 둔 절차다 (기록으로 남긴다).
0.4.6.24 는 실기 통과분이고 이 판은 *누가 종료를 선언하는가* 를 바꿨으므로,
확인할 것은 하나다.

```text
오프닝 Track 17 · 44.72 초에 자막이 사라지고 VRAM 이 복원되는가
  사라지면    회수 성공.  ADPCM 트리거를 25 B 안에 넣는 작업으로 넘어간다
  안 사라지면 엔진의 STX 가 안 불리는 것.  X == 3 도달 경로를 다시 본다
```

Power Cycle 후 후보 BIOS 와 CUE 를 열고 **Lua 를 하나도 로드하지 않는다.**

#### 부작용 (의도된 것)

`elapsed` 가 `$5E1A` -> `$5E1D` 로 밀렸다.  0.4.6.24 는 그 주소를 어서션으로
묶었는데 그것은 **BIOS 가 elapsed 를 읽었기 때문**이다.  이제 안 읽으므로 제약이
사라진다.  대신 새 빌더는 "엔진 이미지에 `STX $7FDF` 가 있는가" 를 확인한다.

### 11.7 회수한 25 B 에 넣을 ADPCM 트리거 — 설계 (미구현)

> ⚠ **이 절은 두 곳이 반증됐다 -> §11.9 를 먼저 읽을 것.**
> (1) "$22A7 을 0 으로 지우는 방식은 못 쓴다" 는 틀렸다. 0.4.6.20/21/22 가
>     실기에서 계속 그렇게 해왔고, bit20 조건이 경합 창을 닫는다.
> (2) 이 절이 트리거를 **독립 작업**처럼 적은 것이 0.4.6.26/27 을 연달아
>     깨뜨렸다. §9.1 의 1->5 는 나열이 아니라 의존 순서다.
> (3) 이 트리거 자체가 §12 로 폐기됐다. LBA 판별기가 대신한다 --
>     $22A6/$22A7/$22AA 를 보지 않으므로 재무장 가드도 스크래치 RAM 도
>     76 B 예산 압박도 없다.

§9.1.1 실측으로 키 3 B 가 평범한 RAM 이라는 것이 확정됐다.  BIOS decision 에는
**키를 만들 필요가 없다** -- 상태 1 만 세우면 되고, 키 생성과 lookup 은 engine 이 한다
(CD-DA 가 이미 그 규칙이다).

```asm
    LDA $22A7        3      finish 상위.  음성마다 다르다
    BEQ idle         2      0 = 재생 없음
    CMP last         3      직전에 잡은 값과 비교
    BEQ idle         2      같으면 이미 처리한 음성
    STA last         3
    LDA #$01         2
    STA $7FDF        3      state 1
    RTS              1
                    ---
                    19 B   (여유 25 B 안에 들어간다)
```

#### ⚠ `$22A7` 을 우리가 0 으로 지우는 방식은 **못 쓴다**

그러면 `last` 가 필요 없어 14 B 로 줄지만, 게임은 `$F5E7` 에서 그 값을 쓰고
`$F604` 에서 읽는다.  그 사이에 우리 게이트가 끼면 **엉뚱한 주소에서 음성이
재생된다.**  몇 명령 차이라 실제로 일어날 수 있다.  안전하지 않다.

#### 남은 의존성 하나 — `last` 를 둘 안정된 RAM 1 B

정적으로 여기까지 좁혔다.

```text
$7F49-$7FDF   resident 151 B                     꽉 참
$7FE0-$7FE7   preload 로더의 행 버퍼 8 B         사용 확정
              (build_subtitle_native_poll_bios_0_8_4.py: VARS=$7FE0, CPX #8 루프,
               3 행을 8 B 씩 재사용)
$7FE8-$7FFF   24 B                               ★ 정적 참조 없음.  그러나 미증명
```

★ **정적 참조가 없다는 것은 비었다는 증거가 아니다.**  그 구간은 뱅크 `$6A` 의
게임 작업 RAM 이고 게임 자신이 쓸 수 있다.  프로젝트 규칙대로 **런타임 쓰기 감시로
여러 장면에서 죽어 있음을 확인한 뒤에만** 쓴다.

    다음 측정: `$7FE8-$7FFF` 에 대한 읽기 전용 쓰기 감시.
    한 바이트라도 게임이 건드리면 그 자리는 탈락이고, 전부 조용하면 1 B 를 가져온다.

(참고: BIOS 뱅크 0 을 스캔해 이 영역 접근을 찾으려 했으나 **답을 낼 수 없는 측정**이었다.
 그 변수를 쓰는 코드는 BIOS 가 아니라 런타임 적재 블롭(`$7E64`) 안에 있다.
 "접근 0 건" 은 자유롭다는 뜻이 아니라 엉뚱한 곳을 봤다는 뜻이었다.)

### 11.8 ✗ 0.4.6.26 실패 — 게이트가 계속 열려 크래시 (2026-08-30)

> ⚠ **아래의 원인 지목은 실측으로 틀린 것이 확인됐다 -> §11.9.**
> `$180D` bit `$20` 은 가정대로 재생 종료와 동시에 0 이 된다(0.5.30).
> 진짜 원인은 그 비트가 **레벨이라 재생 중 매 프레임 열린 것**이고,
> 0.4.6.26 이 0.4.6.22 에 있던 `STZ $22A7` 재무장 가드를 지운 것이다.

회수한 25 B 에 ADPCM 감지기를 넣어 CD-DA 와 합쳤다.  decision 75/76 B 로 정적
빌드·디스어셈은 통과했으나 **실기에서 크래시**했다.

```text
FRAGMENT WIPE #77 ... #326   전부 "VRAM SATB 0칸 · Sprite RAM 0칸"
PATCHED base=$1600           키 기반 주소가 아니라 고정 기본값
-> 게이트가 매 프레임 열린다.  상주부가 helper/renderer 를 무한 재적재하다 죽는다
```

#### 원인 — **검증하지 않은 가정**

감지기의 마지막 줄이다.

```asm
LDA $180D / AND #$20 / BEQ idle      "재생 중이면 통과"
```

여기에 **"음성이 끝나면 이 비트가 0 이 된다"** 는 가정을 얹었다.  그래야 같은
음성으로 두 번 무장하지 않는다.  그런데 **그것을 한 번도 재지 않았다.**
`build_subtitle_native_poll_bios_0_8_4.py` 의 게이트 코드를 읽고 추측했을 뿐이다.

기존 게이트는 `CMP #$68` 로 음성 하나만 받았기 때문에 이 문제가 드러나지 않았다.
그 조건을 빼면서 드러났다.

    ★ 교훈 -- 오늘 하루 "재보고 믿자" 로 일관했는데 마지막에 안 재고 넣었다.
      `$180D` 비트 의미는 **측정 대상이지 독해 대상이 아니다.**

#### 되돌리기

```text
BIOS  0.4.6.22-dictionary-key-vram
Lua   lua/SUB/0.4.93-hq-key-vram.lua
```
0.4.6.26 은 쓰지 않는다.  0.4.6.25(CD-DA 단독)는 실기 PASS 이므로 유효하다.

#### 넣기 전에 쟀어야 할 것 (다음 세션의 첫 작업)

읽기 전용 프로브로 **음성 한 개 동안** 다음을 프레임 단위로 기록한다.

```text
$180D bit $20     시작 · 유지 · 종료에서 어떻게 변하는가.  조각 사이에 0 이 되는가
$22A7             음성이 끝난 뒤에도 값이 남는가 (남으면 재무장 조건이 못 된다)
$22A6 / $22AA     같은 구간에서의 움직임
$7FDF             state 가 실제로 몇 번 1 이 되는가
```

이 그래프가 나오면 감지 조건이 산술로 정해진다.  나오기 전에는 넣지 않는다.

### 11.9 ✗ 0.4.6.27 실패 — 고칠 곳은 맞았는데 **순서**가 틀렸다 (2026-08-30)

0.5.30 / 0.5.31 실측으로 §11.8 의 원인 지목을 정정하고, 그에 맞춰 0.4.6.27 을
만들어 실기에 올렸다.  **또 깨졌다.**  다만 이번엔 깨진 이유가 다르다.

#### 먼저 — §11.8 의 원인 지목은 틀렸다 (실측)

§11.8 은 "`$180D` bit `$20` 이 음성 종료 후 0 이 된다는 가정을 안 쟀다" 를 원인으로
적었다.  프레임 단위로 재보니 **그 비트는 가정대로 정확히 동작한다.**

```
0.5.30 timeline
  frame 5060  play  d180D=60  bit20=1
  frame 5061  tail  d180D=00  bit20=0      <- 재생 종료와 동시에 정확히 0
```

진짜 원인은 음성 **하나**에 게이트가 **183 번** 열린 것이다.

```
0.5.31 후보 게이트 모의 실행 (음성 2 개)
  A   $180D & $20 만        489 회    <- 0.4.6.26 이 이것이다
  B   $180C & $08           489 회    <- 포트 상태 비트도 똑같이 레벨이다
  A2  A + last 변수           2 회
  C   $22A7 변화만            2 회
  D   $22A6/A7/AA 3 B 변화    2 회
  V   실제 음성                2 회
```

`$180D & $20` 은 **에지가 아니라 레벨**이다.  종료 후에 열리는 게 아니라 재생 중
매 프레임 열린다.  §11.8 이 "그 비트가 직전 값 기억을 대신한다" 고 적은 것이
애초에 성립하지 않았다.

#### 에지 메모리는 처음부터 있었다 — 0.4.6.26 이 그것을 지웠다

실기 PASS 판 0.4.6.22 의 게이트 끝은 이렇다.

```asm
$FEF1  A9 01      LDA #$01
$FEF3  8D DF 7F   STA $7FDF        state 1
$FEF6  9C A7 22   STZ $22A7        ★ 에지 메모리
$FEF9  60         RTS
```

이미지 전수 대조.

```
0.4.6.20 / .21 / .22   9C A7 22 있음 ($FEF6)              실기 PASS
0.4.6.23 / .24 / .25   ADPCM 게이트 자체가 없음 (CD-DA 전용)  PASS
0.4.6.26               이미지 전체에 없음                   ✗ 크래시
```

#### §11.7 의 경고도 반증됐다

"⚠ `$22A7` 을 0 으로 지우는 방식은 못 쓴다 -- `$F5E7` 쓰기와 `$F604` 읽기 사이에
끼면 엉뚱한 주소에서 재생된다."

그 경합은 일어날 수 없다.  게이트는 `$180D & $20` 이 서야 열리고 그 비트는
`$F618` 에서 선다.  그때 `$F601 LDX $22A6 / LDY $22A7` 은 이미 지나갔다.
**bit20 조건이 경합 창을 닫는다.**  그리고 0.4.6.20/21/22 가 실기에서 계속 해왔다.

#### 그래서 0.4.6.27 을 만들었다 — 그리고 또 깨졌다

```
STZ $22A7 복원 (ADPCM 경로 전용 · fall-through 로 CD-DA 는 제외)   +3 B
rate 사전검사 제거 (예산)                                          -7 B
decision 71/76 B · 여유 5 B
```

가드 자체는 옳다.  깨진 곳은 그 **뒤**다.

```
PATCHED base=$1600        키가 안 맞아 렌더러 기본값으로 떨어진다
FRAGMENT WIPE #11878      그 상태로 계속 돈다
-> $1600 은 검증된 안전 VRAM 위치가 아니다.  게임 VRAM 을 밟는다
   접수처 첫 대사가 깨지고 그 뒤 크래시
```

#### 원인 — fail-closed 가 **Lua 쪽에만** 있다

Lua 사슬을 끝까지 폈다.

```
0.5.29 -> 0.4.93 -> 0.4.89 -> 0.4.48 -> 0.4.45 -> 0.4.31
```

`0.4.31:221` 에 fail-closed 가 실제로 있다.

```lua
local ok = SELECT_BASE(voice.id, 1, 'start')
if ok == false then
  emu.log('MAP SKIP ' .. voice.id)   -- 표 밖 음성은 자막을 안 연다
  return
end
```

그런데 이 블록은 `emu.callbackType.exec, GATE` 콜백 안에 있다.  **Lua 가 자기
게이트를 통과시킬 때만** 돈다.  네이티브 게이트는 그 표를 아예 묻지 않고 곧장
`state 1` 을 세운다.  `MAP SKIP` 은 찍힐 기회가 없다.

    ★ 0.4.6.22 가 안전했던 이유는 가드가 아니라 `CMP #$68` 이었다.
      그것이 1 번(감지)을 사실상 무력화해 2~5 를 우회할 경로 자체를 막고 있었다.

#### 교훈 — §9.1 의 1→5 는 나열이 아니라 **의존 순서**다

```
1  음성 감지          ✔ 0.4.6.27 로 됨.  STZ $22A7 가드도 유효
2  6 B 키 만들기      ✗ 아직 Lua      ← 여기가 비면
3  팩 조회            ✔ 이미 네이티브
4  selector 전환      ✗ 아직 Lua
5  미등록 fail-closed ✔ 이미 네이티브 (단, 3 이 키를 받아야 작동)
```

1 만 옮기면 2·4 가 빈 채로 3·5 에 도달하지 못한다.  **감지기 단독은 출하 단위가
아니다.**  이 문서 §11.7 이 "회수한 25 B 에 넣을 ADPCM 트리거" 를 독립 작업처럼
적은 것이 이 실수를 두 번 부른 원인이다.

#### 3·5 는 이미 네이티브다 (이번에 확인)

`build_subtitle_engine_ac_record_poc.py`

```
index_loop / index_compare    AC 색인 선형 검색 (wide_lookup: 최대 65535 항목)
:126  STZ ENGINE_LO / RTS     끝까지 못 찾으면 매직 해제 + 종료 = fail-closed
```

즉 **엔진이 selector 에 올바른 6 B 키를 받기만 하면** 미등록 음성은 저절로
조용히 종료한다.  새로 만들 것이 아니라 키를 물려주는 일이다.

#### 3 B 부분키는 안 된다 (실측)

```
팩 색인 1950 조각 · 서로 다른 6 B 키 902 개
앞 3 B($22A6/$22A7/$22AA) 접두는 33 종류뿐
그 33 개 중 조각 하나만 가리키는 것은 2 개
```

ADPCM RAM 3 표본(key[3..5])은 못 뺀다.  §9.1.1 의 판단이 맞았다.

#### 훅 자리 확인 (정적)

```
$F5F2:  8D AA 22   STA $22AA      <- 정확히 3 B.  JSR abs 로 치환된다
$F5F5:  AE A8 22   LDX $22A8      <- 게임이 ADPCM 포인터를 만지기 시작하는 곳
```

§9.1.1 이 제안한 훅 자리가 실물로 확인됐다.  그 사이에 샘플링하면 포인터를
복원할 필요가 없다.

#### 남은 병목 두 개 — 0.5.32 가 잰다

```
1  훅에서 뜬 3 B 를 엔진까지 나를 스크래치 RAM 3 B
     $7FE8-$7FFF 는 0.5.30 에서 죽었다 (24 B 전부 게임이 쓴다, PC $EA9E)
     다음 후보는 $2280-$22FF (드라이버 변수와 같은 페이지)

2  가드를 STZ $22A7 -> $22A6 표식으로 옮길 수 있는가
     지금 가드는 $22A7 을 지운다.  그러면 엔진이 key[1] 을 못 읽는다
     $22A6 은 finish 하위이고 실측 9/9 항상 $00 이라 키에 정보가 없다
     조건: 게임이 $F601 이후로는 $22A6 을 읽지 않아야 한다
```

#### 되돌리기

```
BIOS  0.4.6.22-dictionary-key-vram
Lua   lua/SUB/0.4.93-hq-key-vram.lua
```

0.4.6.27 은 보관하되 쓰지 않는다.  빌더는 남긴다 -- `STZ $22A7` 회귀 방지 3 단계
(어셈블 · fall-through 배치 · 최종 이미지)가 들어 있고, 그 부분은 유효하다.

#### 측정 도구가 답을 못 내던 결함도 같이 고쳤다

0.5.30 은 포트 창을 `$1800-$180F` 로 잡아 **CD-ROM 레지스터** 쓰기가 폭주했고
(쓰기마다 `emu.getState()`), 게임이 기어가 "부팅이 안 된다" 로 보였다.  게다가
그 폭주가 이벤트 상한을 부팅 중에 다 먹어 정작 필요한 것이 한 건도 안 남았다.
0.5.31 도 `$22A6` 읽기 800 건이 전부 부팅 중 idle 이었다.

    0.5.32 는 이벤트를 안 적는다.  주소별 카운터만 세고 PC 조회는 주소·종류당
    최초 1 회뿐이다.  상한이 없어 전 구간이 남는다.

---

## 12. ★★ 런타임 식별을 LBA 로 바꾼다 — 실측으로 확정 (2026-08-30)

§9.1.1 이후로 "네이티브가 6 B 키를 만든다" 를 전제해 왔다.  그 전제가 **필요 없어졌다.**
음성의 **시작 LBA 3 바이트가 평범한 콘솔 RAM 에 있다.**

### 12.1 어떻게 나왔나 — CD-DA 를 흉내내라는 지적에서

CD-DA 는 `$26F9`(트랙 번호) 한 바이트로 식별한다.  "ADPCM 도 같이 감지하면 되지
않나" 라는 지적에서 출발해 그 대응물을 찾았고, 그것이 **섹터(LBA)** 였다.

수집표(`snatcher_tool/translation/voice_console_keys.tsv`, 1055 행)로 먼저 채점했다.

```text
고유 6B키                                  1025
고유 섹터                                  1047     한 섹터가 2+ 키를 가리킴:  5
(read_addr, end, rate) 판별자               612     한 판별자가 2+ 키:       251
```

주소 조합이 251 번 충돌하는 이유가 실측으로 나왔다.

```text
같은 (시작,끝) ADPCM 버퍼를 공유하는 서로 다른 음성 그룹  251
그중 최대                                              10 개 음성이 한 버퍼를 공유
```

**주소는 그릇이지 정체성이 아니다.**  게임이 같은 ADPCM 버퍼에 다른 음성을 계속
덮어쓴다.  그래서 v6 이 내용(ADPCM RAM 3표본)으로 키를 잡았던 것이고, 같은 이유로
그 표본을 뺄 수 없다고 §9.1.1 이 판단했다.  둘 다 맞다.

그러나 **섹터는 정체성이다.**  그리고 섹터는 콘솔이 볼 수 있다.

### 12.2 정적 분석 — LBA 는 SCSI CDB 에 있다

`AD_TRANS ($E033 -> $F393)` 가 명령을 조립하는 과정.

```asm
$F3B1  JSR $F0EE            ; $224C..$2254 (CDB 9 B) 0으로 지움
$F3B4  LDA #$08 / STA $224C ; SCSI opcode $08 = READ(6)
$F3B9  JSR $F104            ; LBA 산술 -- 호출자의 상대값에 베이스를 더한다
$F3BC  LDX #$04 / LDY #$01
$F3C0  JSR $F327            ; ★ LBA 3 B 복사
$F3C3  LDA $F8 / STA $2250  ; 전송 섹터 수
$F3C8  JSR $E900            ; 명령 발행

$F327  LDA $F8,X / STA $224C,Y      X=4, Y=1 이므로
       LDA $F9,X / STA $224D,Y  ->   $FC -> $224D
       LDA $FA,X / STA $224E,Y       $FD -> $224E
       RTS                           $FE -> $224F
```

```text
$224C              SCSI opcode ($08 = READ(6))
$224D/$224E/$224F  24-bit LBA (MSB first)   ★ 시작 섹터
$2250              전송 섹터 수
```

`CD_READ ($E009 -> $FF10 -> $EC05)` 도 **같은 CDB 를 같은 방식으로** 채우고
`$EC4E JSR $E900` 으로 발행한다.  ($FF10 은 이 KO 빌드의 래퍼다.  본체는 $EC05)

⚠ 제로페이지 `$FC/$FD/$FE` 는 쓰지 않는다.  그것은 **상대값**이고 `$F104` 가
베이스를 더한다 (실측 5/5 로 차이가 상수 `0x104E`).  베이스가 바뀌면 깨진다.
반드시 CDB 쪽(`$224D`)을 읽는다.

⚠ 제로페이지는 물리적으로 `$2000-$20FF` 다.  `$FC` 를 읽으려면 `$20FC` 를 읽어야 한다.

### 12.3 수집표의 `sector` 는 **끝 섹터**였다 (0.5.33)

```text
scsi = first + ceil(audio_length / 2048)

VOICE #2  003057 + 20 = 00306B   len $9F90 -> 20 섹터
VOICE #3  00306B + 13 = 003078   len $6794 -> 13 섹터
VOICE #4  003078 + 11 = 003083   len $579D -> 11 섹터
VOICE #5  003083 + 26 = 00309D   len $CF9B -> 26 섹터
```

수집기가 `cdrom.scsi.sector` 를 재생 시작 때 읽었는데, 그것이 **그 명령의 끝 섹터**다.
어긋남도 프리페치도 아니다 -- 같은 한 번의 읽기다.

그래서 **재수집이 필요 없다.**  기존 1055 행에서 오프라인으로 파생한다.

```text
시작LBA = 수집sector - ceil(audio_length / 2048)

파생 시작LBA 고유값                1053 / 1055
한 시작LBA 가 2+ 키를 가리킴          2      <- 끝섹터(5건)보다도 낫다
```

### 12.4 커버리지 실측 (0.5.34, 음성 29 개)

```text
음성 29 · 자막 대상 27 · 효과음 2
자막 대상 적중             27 / 27   (100%)
전부 AD_TRANS · 전부 뒤로0 · 전부 end=scsi 1
CD_READ 로 잡힌 것          0
못 맞춘 것                  1 -- has_subtitle=0 인 효과음
```

**`뒤로0` 이 27/27** 이라는 것이 핵심이다.  음성 **직전 명령이 곧 그 음성의 적재**다.
링을 뒤질 필요도, 후보를 고를 필요도 없다.  발행 시점의 3 B 를 그대로 쓴다.

효과음이 안 잡히는 것은 **정상이다.**  재생 직전에 적재하지 않고 미리 올려두므로
직전 명령이 없다.  그리고 팩에 키가 없으므로 조회가 fail-closed 한다 (§9.1-5).

### 12.5 ★★ 부수 발견 — 기존 게이트는 자막 음성의 17.7% 를 원천 차단한다

실기 로그에 `FFFF0E400014` / `FFFF0E279000` 두 키가 나왔다.  둘 다 `has_subtitle=1`.
키의 첫 바이트는 `finish` 하위인데 `$00` 이 아니라 `$FF` 였다.  팩 전체를 셌다.

```text
팩 고유 6B키 902
key[0] = $00   742
key[0] = $FF   160      <- 17.7%
```

그런데 지금까지 만든 **모든** BIOS 게이트의 첫 줄이 이것이다.

```asm
LDA $22A6 / BNE idle      ; "finish 하위는 늘 $00 (실측 9/9)"
```

§9.1.1 이 음성 **9 개**로 세운 가정이 902 개 중 **160 개에서 틀린다.**
0.4.6.26/27 이 재무장 문제를 다 고쳤어도 이 160 개는 영영 자막이 안 떴을 것이다.
표본이 9 개라 드러날 수가 없었다 -- §11.9 와 정확히 같은 종류의 실수다.

    ★ 교훈 -- "실측 9/9" 는 9 개를 봤다는 뜻이지 902 개가 그렇다는 뜻이 아니다.
      팩에 902 개가 이미 있었으므로 **세어보면 되는 일이었다.**

⚠ 정직하게: 팩 키의 `key[0] = $FF` 는 직접 셌다.  그 순간 `$22A6` 이 실제로 `$FF`
라는 것은 §9.1.1 의 "`$22A6` = finish 하위 (9/9)" 로부터의 **추론**이다.
LBA 방식은 `$22A6` 을 보지 않으므로 확인할 필요가 없어진다.

### 12.6 그래서 무엇이 바뀌나

```text
폐기   ADPCM RAM 3표본을 콘솔에서 뜨는 계획 (§9.1.1 제안 · §5 "가장 먼저 실측")
       -> 포트를 건드릴 일이 없으니 재생 교란 위험도 같이 사라진다
폐기   $22A6/$22A7/$22AA 기반 BIOS 게이트 (§11.7 · 0.4.6.26 · 0.4.6.27)
       -> 재무장 가드도, 스크래치 RAM 3 B 사냥도, 76 B 예산 압박도 필요 없다
유지   네이티브 AC 색인 검색 · fail-closed · 16-bit 조각 scheduler
       (engine_ac_timed_safe_poc 669 B -- 0.4.31 이 기본으로 쓰는 그 엔진)
```

그리고 **CD-DA 와 합쳐진다.**  팩의 CD-DA 색인이 이미 `LBA 3+3` 구조다
(`CDDA_STRIDE = 10`).  ADPCM 도 시작 LBA 로 색인하면 같은 모양이 되고,
LBA 판별기 하나가 둘을 다 받는다.  CD-DA 도 Track 17 하드코딩에서 풀린다.

### 12.7 다음 작업

```text
1  팩에 ADPCM 시작-LBA 색인 추가
     데이터는 오프라인 파생 (재수집 0).  §12.3 의 식
     ⚠ §6.3 -- 지금 팩을 통째로 재빌드하면 CD-DA 색인이 698 -> 0 이 된다
       (한국어 번역 대기).  CD-DA 색인을 보존하도록 빌더를 손봐야 한다
2  AD_TRANS 발행($F3C8)에 훅 -> $224D-$224F 3 B 스냅샷
     코드는 BIOS bank 1 에 둔다 (§3: $F0EA-$FC76 등 ~4.7 KB 여유)
     76 B decision 예산과 무관하다
3  스냅샷한 LBA 로 색인 조회 -> 9 B selector 기입 -> state 1
     조회 실패는 무개입 (효과음이 여기로 걸러진다)
4  CD-DA 를 같은 판별기로 흡수 -> Track 17 고정 해제
```

### 12.8 이 절을 만든 측정

```text
0.5.33-adpcm-lba-source.lua      AD_TRANS 진입/발행에서 CDB LBA 포착 · 4 후보 대조
0.5.34-adpcm-lba-coverage.lua    AD_TRANS + CD_READ 양쪽 · 섹터수 자기채점 · 자동집계
```

둘 다 읽기 전용이고 ADPCM 포트를 건드리지 않는다.
0.5.34 는 명령의 `$2250`(섹터 수)와 `ceil(음성길이/2048)` 을 맞춰 **표 없이** 채점한다.
