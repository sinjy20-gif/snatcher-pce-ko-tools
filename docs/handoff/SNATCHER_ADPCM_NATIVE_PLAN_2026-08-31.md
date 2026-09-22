# SNATCHER ADPCM 네이티브화 계획 — 2026-08-31

## 결론

ADPCM 네이티브 식별은 ADPCM RAM을 읽어 6바이트 지문을 만드는 방식으로 가지 않는다.
최신 실측 결론은 `AD_TRANS`가 발행하는 SCSI CDB의 **시작 LBA 3바이트**를 읽고,
그 LBA로 기존 ADPCM 런타임 키와 자막 record를 찾는 방식이다.

이 방식은 ADPCM RAM 포트를 건드리지 않으므로 재생 교란 위험이 없고, CD-DA도 같은
LBA 판별기로 흡수할 수 있다.

## 현재 기준과 확인 결과

```text
팩 원본                         build/cutscene_subs/subtitle_pack.bin
LBA 확장 검사본                 build/cutscene_subs/subtitle_pack_lba.bin
현재 자막 팩 LBA 색인            902 항목 · stride 9 B · 100% subtitle-pack coverage
전체 음성 마스터                 1,055 행
runtime key가 있는 전체 음성      1,046 행 · 고유 runtime key 1,024개
사용자 명시 효과음               39개 (`voice_keys.tsv`의 `kind=효과음`만)
LBA 항목                         시작 LBA 3 B (MSB first) + runtime key 6 B
원본 팩                          183,918 B · 본문 바이트 변경 없음
확장 팩                          192,036 B · AC 192 KiB 한도 이내
전체 마스터 색인                 1,046개 native lookup · 시작 LBA 충돌 0개
```

`tools/build_pack_lba_index.py`의 기본 실행은 검사 및 별도 파일 생성을 한다.
`--apply`는 아직 실행하지 않는다. CD-DA 색인이 빠진 팩을 다시 굽는 회귀를 막기
위해, 적용 전에 빌더가 ADPCM/CD-DA 두 색인을 함께 보존하는지 먼저 고친다.

### ⚠ 2026-08-31 기준 정정 — 902는 전체 음성 수가 아니다

앞서 만든 `subtitle_pack_lba.bin`의 902개는 **현재 자막 팩에 들어 있는 키만** 센
값이다. 전체 대상으로 확장할 때 `has_subtitle=0`, `status`, 추정된 내용만으로
효과음을 분류하지 않는다. 효과음은 `voice_keys.tsv`에서 사용자가 명시한
`kind=효과음` 39개만 그렇게 취급한다.

따라서 다음 전체 색인은 아래 세 부류를 보존해야 한다.

```text
대사/미표시 전체       기본 대상
명시 효과음 39개       효과음 표식만 유지
runtime key 누락 9개   식별 불가로 별도 miss/보류 기록
```

전체 색인 생성 결과:

```text
도구        tools/build_adpcm_lba_master_index.py
binary      build/cutscene_subs/adpcm_lba_master_index.bin (9,414 B)
TSV/JSON    같은 이름의 .tsv · .json
마스터      1,055행
runtime     1,046행 · 고유 key 1,024개
명시 효과음 39행 중 runtime key 보유 34행
LBA 충돌    0개
runtime 누락 9행
```

이 색인은 원본 자막 팩과 분리된 전체 감지용 산출물이다. 아직 BIOS나 원본
`subtitle_pack.bin`에는 연결하지 않았다.

전체 음성 LBA 색인은 자막 record가 없는 항목도 포함할 수 있어야 한다. 단, native
renderer를 여는 것은 실제 자막 record가 있고 사용자 규칙상 대상인 항목으로
제한한다. 즉 `전체를 감지`하는 것과 `전체에 자막을 표시`하는 것은 분리한다.

## 네이티브 계약

```text
AD_TRANS 발행 직전
  $224D/$224E/$224F = 시작 LBA 3 B (MSB first)

native dispatcher
  LBA를 LBA+runtime-key 색인에서 검색
  성공: 같은 음성의 첫 9 B selector를 기록하고 state=1
  실패: 아무것도 하지 않음 (효과음 및 미등록 음성 fail-closed)

기존 AC 엔진
  selector로 ADPCM index/record 검색
  16-bit 조각 scheduler
  음성 종료 후 1프레임 delayed restore
```

기존 `$22A6/$22A7/$22AA` 게이트와 `$22A7`을 지우는 재무장 방식은 최종 경로에서
사용하지 않는다. `key[0]=$FF`인 자막 음성이 160개 있어 기존 finish 하위 바이트
검사는 17.7%를 차단한다.

## 단계별 실행 계획

### 1. 팩·색인 계약 고정

1. 전체 마스터 1,055행을 `voice_keys.tsv`의 명시적 `kind`와 join한다.
2. runtime key가 있는 1,046행에서 전체 LBA+key 목록을 만든다.
3. `subtitle_pack_lba.bin`의 헤더와 원본 본문을 byte 비교한다.
4. ADPCM 색인 1,950조각과 현재 자막용 LBA+key 902항목의 연결을 검증한다.
5. CD-DA 색인 698개가 유지되는 통합 팩을 만든다.
6. 팩 빌더·검증기·BIOS loader의 offset/total 계산을 함께 갱신한다.

완료 기준: 기존 ADPCM record/glyph/CD-DA 데이터가 이동하지 않고, 전체 음성
감지표와 자막 표시용 색인이 각각 검증기를 통과한다.

### 2. AD_TRANS LBA snapshot POC

출발점은 `tools/build_snatcher_0_4_7_0_lba_probe.py`의 검증된 CDB 접근이다.
관측용 결과 기록을 다음의 네이티브 내부 입력으로 바꾼다.

```text
$224D/$224E/$224F 읽기
→ 안전한 내부 3 B snapshot
→ dispatcher 호출
```

이 단계에서는 자막 state를 열지 않고 snapshot과 lookup 결과만 기록한다.
ADPCM 시작 LBA 5개 이상, 효과음 1개, CD-DA 시작 1개를 통과시킨다.

### 3. D000 단일 음성 연결

이전 계획의 D000 3조각 시험은 유지하되, 식별 입력만 LBA 방식으로 한다.
ADPCM RAM 3표본 reader는 넣지 않는다.

```text
대상        ADPCM_00309D_D000_0E
조각        3개
VRAM        고정 $1600-$1ABF
식별        AD_TRANS 시작 LBA
엔진        16-bit scheduler
종료        다음 $601E에서 delayed restore
Lua         0개
```

통과 기준은 90/180프레임 조각 전환, 종료 후 진행, 다음 음성, 타이틀 복귀,
화면 잔상 없음이다.

### 4. 범용 ADPCM dispatcher

단일 음성 POC가 통과한 뒤 902개 LBA+key 항목을 네이티브 색인으로 확장한다.

```text
LBA hit       → runtime key/record/첫 selector 연결
같은 음성     → 1~11개 조각 mini index 구성
LBA miss      → state를 열지 않음
효과음        → 자막/VRAM을 건드리지 않음
```

selector 전환과 `ready=0`은 `$601E` resident 경로의 scheduler가 담당한다.
BIOS IRQ 대기 루틴 `$E736~$E74C` 안에서 엔진을 직접 재빌드하지 않는다.

### 5. 전체 ADPCM 검증

Lua 기준판과 네이티브판을 같은 세이브 스테이트로 비교한다.

```text
902키 중 검증된 항목
다중 조각 전환
음성 종료/복원
미등록 음성·효과음 무개입
진행불가 없음
```

특히 기존 `ADPCM_008FA4_FFFF_0E`는 `$20F5` IRQ 동결 회귀 시험으로 사용한다.
`$E736` 반복, stack 감소, `VOICE_END` 미도달이 다시 나오면 결합을 중단하고
dispatcher/scheduler 호출 위치를 되돌린다.

### 6. CD-DA 최종 결합

ADPCM 전체 검증 후에만 CD-DA를 같은 LBA dispatcher에 연결한다.
Track 17 하드코딩을 제거하고, 공용 owner/state와 CD-DA frame/LBA scheduler를
추가한다. ADPCM과 CD-DA가 겹칠 때의 owner 우선순위는 실제 겹침 로그를 확인한
뒤 결정한다.

## 금지 사항

```text
· ADPCM RAM 샘플링과 LBA 식별을 한 판에 섞지 않는다
· D000 POC와 902키 전체 연결을 동시에 하지 않는다
· $E736/$E742 IRQ 대기 루틴 안에서 renderer rebuild를 직접 호출하지 않는다
· 원인 writer 확인 전 자막 훅/ALLOCATOR를 다시 수정하지 않는다
· CD-DA 색인이 698 -> 0이 되는 팩 전체 재빌드를 허용하지 않는다
```

## 다음 실제 작업

```text
1  LBA 확장 팩의 ADPCM/CD-DA 양쪽 헤더·본문 검증
2  전체 음성용 LBA 감지표와 현재 자막용 record 색인을 분리
3  AD_TRANS snapshot만 하는 native POC 작성
4  D000 3조각에 snapshot→lookup→state 1 연결
5  실기 검증 후 범용 dispatcher로 확장
```

## 2026-08-31 작업 결과

902개 자막 팩과 분리한 전체 ADPCM 마스터 관찰판을 만들었다.

```text
전체 마스터                 1,055행
런타임 키 보유              1,046행
고유 runtime key            1,024개
명시적 kind=효과음           34행
LBA 충돌                     0개
```

산출물:

```text
build/cutscene_subs/adpcm_lba_master_index.bin
build/cutscene_subs/adpcm_lba_master_dispatcher.bin
build/cutscene_subs/adpcm_lba_master_index_upload.bin
build/patch/0.4.6.28/Syscard3_galmuri_0.4.6.28.pce
build/patch/0.4.6.28/TEST_IN_MESEN.txt
lua/SUB/0.5.46.lua
```

0.4.6.28은 0.4.7.0 디스패처의 관찰 동작을 유지한다. ADPCM 시작 LBA를 전체
1,046행 색인에서 조회하고 AC 관측 슬롯에 결과만 쓴다. 자막 렌더링, selector,
state 변경은 없다. 0.5.46은 Lua에서 표를 자동 업로드하고 음성 시작마다
native key와 실제 ADPCM key를 자동 비교하므로 수동 키 입력이 필요 없다.

효과음은 `voice_keys.tsv`의 `kind=효과음` 표식만 신뢰한다. 미표시 항목을
효과음으로 추정하거나 `has_subtitle=0`을 효과음으로 바꾸지 않는다. 탐지 대상은
전체 런타임 음성이며, 자막 record 존재 여부는 이후 렌더링 단계에서 별도로
fail-closed 처리한다.

실기 검증 전에는 D000 state 연결과 CD-DA 결합을 진행하지 않는다. 우선 기존
재현 세이브 스테이트로 0.4.6.28 + 0.5.46을 돌려 `BUILD $1C`, status `$A1`,
runtime key 일치를 확인한다.

### 첫 실기 주행 결과

```text
0.5.46 #1  LBA 0A0000  status A0  MISS  (색인 범위 밖의 초기/비음성 호출로 판단)
0.5.46 #2  LBA 003057  status A1  OK
0.5.46 #3  LBA 00306B  status A1  OK
0.5.46 #4  LBA 003078  status A1  OK
0.5.46 #5  LBA 003083  status A1  OK
BUILD 도장 $1C · 탐색 단계 8~10
```

현재까지 실제 음성 4/4가 native key와 실제 ADPCM key 일치다. 첫 `$0A0000`은
전체 색인의 최솟값 `$0010EA`보다도 크지만 최대값 `$009375`를 넘는 LBA라서
마스터 색인 누락이 아니다. 추가 주행에서는 이 패턴이 유지되는지, 그리고
명시적 `kind=효과음` 구간이 게임 진행을 건드리지 않는지만 확인한다. 이 검증이
끝나기 전에는 D000 state 연결을 시작하지 않는다.

### 0.5.47 판정 타이밍 보정

첫 주행의 `NO-HOOK` 두 건은 native 훅 누락으로 확정하지 않는다. 0.5.46이
`cdrom.adpcm.playing` 상승을 본 같은 프레임에 AC 슬롯을 읽었기 때문에, 슬롯
기록보다 먼저 읽는 경합이 가능했다. 0.5.47은 음성 시작을 pending으로 잡고
최대 12프레임 동안 슬롯 status를 자동 polling한 뒤 채점한다. 12프레임 내에도
`$00`이면 그때만 `NO-HOOK`으로 기록한다. BIOS는 바꾸지 않았다.

### D000 실제 자막 POC

`0.5.50.lua`로 `ADPCM_00309D_D000_0E`만 renderer state를 열었다. 실기에서
3조각이 0/90/180프레임에 모두 표시됐고, stage rearm 2회와 fragment/end wipe가
끝까지 실행됐다. 게임 진행도 유지됐다.

첫 시험 팩은 `voice_subtitles_keyed.tsv`의 예전 D000 조각을 사용해 마지막 글자
하나가 잘려 보였다. 최신 마스터 `voice_subtitles.tsv` 기준으로 D000 세 행을
동기화하고 팩/653 B VDC-rearm 엔진을 다시 만들었다.

```text
1  0.000s  1.981s  저는 JUNKER 본부에서
2  1.981s  2.463s  안내와 오퍼레이터를 맡고 있는
3  4.444s  2.189s  미카 슬레이튼입니다. 잘 부탁해요

팩 183,909 B · ADPCM 1,950조각/902음성 · CD-DA 698개
verify_subtitle_pack.py 전부 통과
```

교체 전 팩은 `subtitle_pack.before_d000_master.bin/.json`으로 보존했다.

### Native subtitle routing table

자막 문구/파이프라인과 분리해 native runtime 전용 표를 생성했다.

```text
directory  AC $1F2800  902 LBA route × 6 B = 5,412 B
payload    AC $1F3D24  1,950 fragment       = 26,252 B
end        AC $1FA3B0 exclusive
max parts  11
LBA collision 0 · subtitle key missing 0
```

directory는 `LBA u24 BE + payload absolute pointer u24 LE`, payload는
`count u8 + subtitle_pack ADPCM index entry 13 B[]`다. native BIOS는 이 표만
조회해 engine mini index와 첫 selector를 채울 수 있다. 자막 record가 없는 음성은
directory miss라 state를 열지 않는다. 효과음으로 추정 분류하지 않는다.

### 0.4.6.33 native first-selector armer

`$FEC4`의 첫 `LDA $7FDF`를 bank bridge 호출로 바꾸고, bank1 armer가 다음을
수행한다.

```text
전체 master LBA lookup       1,046 entries @ AC $1FA400
subtitle route 이분검색        902 entries @ AC $1F2800
voice mini index 복사          AC $1EF000
첫 selector 9 B 설치           AC $1F206F
state                          $7FDF = 1
```

VRAM base 일반화 전 안전 POC라 LBA `$003083` D000 하나만 arm한다. 정적 loader
`0.5.51.lua`는 pack/engine/native table을 AC에 올리고 검증된 base `$6600`을
1회 패치한다. runtime callback은 없다. key 생성, route 조회, mini index 복사,
selector 설치, state 전환은 BIOS가 맡는다.

`0.4.6.29`와 `0.4.6.30`은 중간 산출물이므로 사용하지 않는다. 특히 0.4.6.30은
AC 슬롯을 CPU 절대주소처럼 읽던 결함이 있어 폐기했다. 0.4.6.31은 native bridge
뒤에 구형 `$22A7=$68` fingerprint 판정을 계속 실행하여 D000 전 LBA `$00306B`에서
state를 잘못 연 것이 0.5.52 로그로 확인되어 폐기했다.

0.4.6.32는 `$FEC4`의 구형 판정 전체를 우회하면서 원래 수행하던 state 수명주기까지
제거했다. 초기 `$FF`가 0으로 정규화되지 않아 비자막 화면에서 resident가 renderer를
실행하고 VRAM을 깨뜨린 실기 결함이 있으므로 사용하지 않는다.

0.4.6.33은 bank1에서 기존 state 수명주기를 재현했지만 비자막 화면의 VRAM/문자
깨짐이 실기에서 계속 재현됐다. 따라서 0.4.6.32와 0.4.6.33은 모두 폐기하며,
`JSR native bridge ; RTS` 단독 반환 방식은 원인이 확정될 때까지 사용하지 않는다.

안전 기준선은 화면이 깨지지 않았던 `0.4.6.31`로 되돌렸다. `0.5.55.lua`가 0.5.51의
정적 AC 업로드를 수행한 뒤 런타임에는 읽기 전용으로 `$FEC4`, bridge 복귀 `$FEC7`,
구형 gate 승인 `$FEF1`, state 쓰기 `$7FDF`, engine `$5B80`, D000 전후 selector를
자동 기록한다. 이 측정으로 0.4.6.31의 무손상/무표시 사유부터 확정한 뒤 다음 BIOS
구조를 정한다.

#### 0.5.55 기준선 측정 결과 — 무표시 원인 확정

실기 로그 `native_031_trace_20260831_143052.tsv`에서 D000은 다음 순서로 정상
식별됐다.

```text
LBA 003083 · slot A1→A2
state 00→01 (bank1 armer PC F5F4) →02 (resident PC 7F75)
engine CPU magic 535542
```

즉 LBA route 검색과 state/engine 기동은 성공했다. 그러나 arm 전후 selector가
`30 00 00 68 0E 00 00 00 00`으로 변하지 않았다. 이는 D000의 정상 selector
`00 D0 0E 43 77 90 01 00 00`이 아니라 기존 Track24 renderer에 박혀 있던 E6800
고정 selector와 정확히 같다.

원인은 `tools/build_snatcher_0_4_6_29_native_arm.py`의 AC 목적지 포트 계산이다.
Arcade Card 채널 stride는 `$10`이라 port1은 `$1A10`인데, 두 helper가
`$1A00 + port * $100`을 사용해 port1을 `$1B00`으로 계산했다. source port0 읽기는
성공했지만 mini/selector 목적지 쓰기는 AC에 도달하지 않았고 state만 열렸다.

또한 LBA `$00306B`에서 구형 `$22A7=$68` gate가 먼저 state를 연 사실도 로그로
확인됐다. 이는 별도 간섭 요소지만 D000 무표시의 직접 원인은 port1 stride 오류다.
다음 판은 안전 기준선 0.4.6.31에서 포트 stride만 `$10`으로 고쳐 먼저 검증하며,
0.4.6.32/33의 `$FEC4 ... RTS` 구조는 재사용하지 않는다.

#### 0.4.6.34 — 0.4.6.31 + AC port1 stride 단독 수정

`0.4.6.34`는 0.4.6.31의 제어 흐름과 `$FEC4` 바이트
`20 D4 FF C9 FF F0 3F C9`를 그대로 유지한다. armer의 `ac_ptr_const`와
`ac_ptr_local`에서 channel 주소 계산만 `$1A00 + port * $10`으로 수정했다.

0.4.6.31과 완성 BIOS를 비교한 결과 차이는 26 B다. 그중 2 B는 build stamp
`$1F→$22`, 나머지 24 B는 두 port1 설정부의 `$1B02/$1B03/$1B04/$1B07/$1B08/$1B09`
가 각각 `$1A12/$1A13/$1A14/$1A17/$1A18/$1A19`로 바뀐 것뿐이다. 코드 크기도
동일한 1,316 B다.

실기 조합은 `0.4.6.34 + 0.5.56.lua`다. 0.5.56은 정적 데이터를 올린 뒤 D000의
mini 첫 13 B, AC selector, CPU selector와 engine magic을 자동 PASS/FAIL 판정한다.

실기에서 0.4.6.34도 mini/selector가 모두 FAIL했다. 재검토 결과 두 helper의 port1
제어 주소는 `$1A12-$1A19`로 고쳤지만, 실제 mini/selector 복사 루프의 데이터
목적지 두 곳이 여전히 `STA $1B00`으로 하드코딩돼 있었다. 따라서 0.4.6.34도
destination write가 0 B인 것이 정상이며 폐기한다.

#### 0.4.6.35 — port1 data `$1A10`까지 수정

0.4.6.35는 0.4.6.34의 두 `STA $1B00`만 `STA $1A10`으로 수정한다. AC channel
control `$1A12-$1A19`와 data `$1A10`이 모두 같은 port1을 가리킨다. `$FEC4`와
나머지 0.4.6.31 제어 흐름은 그대로 유지한다.

실기 조합은 `0.4.6.35 + 0.5.57.lua`다. 기대값은 mini 첫 entry
`00D00E437790010000C3690000`, selector `00D00E437790010000`, engine magic
`535542`다.

실기 결과 네 항목이 모두 통과했다.

```text
SUB 0.5.57 RESULT mini=OK selectorAC=OK selectorCPU=OK engine=OK
```

D000에서 slot `$A1→$A2`, state `$00→$02`가 확인됐고, arm 전의 stale E6800
selector가 arm 후 정확한 D000 selector로 교체됐다. 따라서 다음 native 구간은
실기로 확정한다.

```text
SCSI start LBA 003083
  → subtitle route 이분검색
  → payload 첫 13 B를 AC mini index에 복사
  → 첫 selector 9 B를 AC engine image에 설치
  → resident가 CPU engine으로 복사
  → state active
```

위 PASS는 데이터 전달만 증명했으며 실제 자막은 표시되지 않았다. 따라서
`0.4.6.35`는 first-selector **data-path** 성공 기준판이지 렌더 성공판은 아니다.

D000 BEFORE에서 active AC engine selector가 Track24의 옛 E6800 고정값
`300000680E00000000`이었던 점으로 보아, 스크립트 시작 때 0.5.51이 `$1F1F00`에
올린 653 B rearm 엔진이 이후 디스크 선적재의 옛 671 B renderer에 덮인 것이
가장 유력하다. 0.4.6.35는 그 옛 이미지에 selector 9 B만 정상 패치했으므로
magic/selector가 모두 OK여도 새 엔진 코드와 VRAM base는 보장되지 않는다. helper
control도 같은 선적재 범위라 시작 때 쓴 `$6600` base가 되돌아갔을 가능성이 있다.

`0.5.58.lua`는 BIOS를 바꾸지 않고 D000 arm 뒤 active AC engine 전체 653 B,
CPU 불변 코드 365 B, helper control base 4 B를 기대 이미지와 자동 비교한다.

0.5.58 실기에서 active engine 395/653 B, CPU code 342/365 B가 불일치했고 helper
control도 `00 16 00 B0`으로 기대값 `00 66 03 30`과 달랐다. 선적재 덮어쓰기가
D000 무표시의 직접 원인으로 확정됐다.

#### 0.4.6.36 — safe engine template 복원

0.5.51은 master 끝 `$1FC8C6` 다음 정렬 주소 `$1FC900`에 base `$6600`이 패치된
653 B rearm engine template을 추가 업로드한다. D000 armer는 arm 순간 다음 순서로
처리한다.

```text
channel1 $1A12-$1A19 문맥 저장
mini payload -> $1EF000
engine template $1FC900 -> active $1F1F00 (653 B)
helper control $1F1DB4 -> 00 66 03 30
첫 selector -> active engine +367
channel1 문맥 복원
state = 1
```

`$FEC4` 흐름은 안전 기준선 0.4.6.31과 동일하다. `0.5.59.lua`는 D000 arm 5프레임
뒤 engine/helper/mini/selector뿐 아니라 실제 engine `entry`, `count_ok`,
`glyph_loop`, `push`, `ready=1`까지 자동 판정한다.

0.4.6.36 실기에서 실제 자막이 처음 표시됐고 native render path가 확인됐다.

```text
active engine mismatch 0 · CPU code mismatch 0
helper 00660330 · mini 정상
hits entry=203 count_ok=2 glyph=19 push=5 ready=$01
renderPath=OK
```

0.5.59의 `selector=FAIL`은 거짓 실패다. 이 엔진은 CPU selector와 sprite list가
같은 주소(+367)를 공유하므로 첫 rebuild 뒤 selector 9 B가 list 데이터로 덮이는 것이
설계상 정상이다. arm 직후 CPU selector는 0.5.57에서 이미 정상임이 확인됐고,
0.5.59에서도 AC selector는 정확했다. 다음 진단은 selector가 아니라 실제 표시된
자막의 시각적 이상(글리프/문장/위치/색/간격)을 화면 캡처로 분류해야 한다.

#### 기준 정정 — 실기 정상 동결팩 `8F20AF38`

0.4.6.36에서 보인 깨진 글리프를 새 renderer 결함으로 재조사하지 않는다. 사용자가
국장실 떨림/뒷화면 소실과 진행을 확인한 기준은 아래 2026-08-30 동결 세트다.

```text
pack  subtitle_pack.frozen_8F20AF38.bin
bytes 183,918
SHA-256 8F20AF388621E4C49ED868B53C95C982B139F77BB875A45CE53FAC93A365289B
BIOS  0.4.6.22-dictionary-key-vram ($7F4A SEI -> NOP)
Lua   0.4.93-hq-key-vram.lua
```

현재 `subtitle_pack.bin`은 이후 재생성된 183,909 B 판이다. 두 팩은 glyph offset이
9 B 다르며, 653 B 엔진에도 이 차이가 실제 피연산자 한 바이트로 박힌다
(`engine +$0C2: DD -> E6`). native payload도 두 판 사이 2,009 B가 달라 현재
payload를 동결 팩과 섞을 수 없다.

그래서 기존 산출물은 덮지 않고 동결 팩에서 다음 짝을 별도 생성했다.

```text
engine_ac_lua_frame_rearm_frozen_8F20AF38.bin      653 B
adpcm_native_subtitle_dir_frozen_8F20AF38.bin    5,412 B
adpcm_native_subtitle_payload_frozen_8F20AF38.bin 26,252 B
lua/SUB/0.5.61.lua
```

`0.5.61.lua`는 위 네 파일과 공통 master만 올린다. BIOS는 안전한 template 복원
경로가 있는 `0.4.6.36`을 그대로 사용한다. D000은 아직 first-selector POC라 이번
판정은 첫 조각이 동결 기준처럼 정상 표시되는지만 본다.

#### 0.4.6.37 — D000 3조각 native frame scheduler

0.4.6.36 + 0.5.61 실기에서 동결 팩의 첫 줄이 깨짐 없이 정확히 표시됐다. 따라서
팩/글리프/record/native armer 연결은 닫고, 같은 frozen 세트를 유지한 채 BIOS에
조각 전환만 추가했다.

```text
BIOS  build/patch/0.4.6.37/Syscard3_galmuri_0.4.6.37.pce
Lua   lua/SUB/0.5.62.lua
code  1,878 / 2,957 B
state $5E0D elapsed u16 · $5E0F part · $5E10 count · $5E11 next ptr u24
```

resident의 `$FEC4` 프레임 호출에서 elapsed를 1씩 올린다. mini의 다음 start_frame
(D000은 90/180)에 도달하면 다음 selector 9 B를 CPU engine에 쓰고, 이전 글리프가
덮어쓴 stage 31 B도 `$1FC900` frozen template에서 복원한 뒤 `ready=0`으로 rebuild를
요청한다. channel1 `$1A12-$1A19`는 매 비교/전환 전후 스택에 보존한다.

0.5.62의 callback은 `$5E0D-$5E10`을 읽어 ARM/PART/END만 로그로 내며 메모리를
쓰지 않는다. 기대 로그는 `PART 2/3 elapsed 90`, `PART 3/3 elapsed 180`이다.

#### 0.4.6.38 — active state 정정

0.4.6.37/0.5.62는 scheduler와 observer를 state `$01`에 걸어 로그가 나오지 않았다.
기존 0.5.57 실기에서 D000 AFTER가 이미 state `$02`였고, resident가 같은 호출 안에서
`1 -> 2`로 넘기므로 다음 프레임 FEC4가 보는 활성값은 `$02`다. 기능 실패가 아니라
상태 기준을 잘못 잡은 것이다.

0.4.6.38은 scheduler 조건을 `$02`로, 0.5.63은 read-only observer 조건을 `$02`로
고쳤다. 0.4.6.37/0.5.62는 사용하지 않는다.

653 B rearm 엔진은 `timed=false`인 Lua-frame 엔진이다. mini의 여러 entry는 검색
후보일 뿐이며 엔진 자체에는 elapsed/part 증가가 없다. 정상 Lua 기준판에서는
0.4.31의 endFrame timer가 selector를 바꿨고, 지금 BIOS scheduler는 그 역할만
네이티브로 이전한다.

#### 0.4.6.39 — scheduler 상태를 AC로 이동

0.4.6.38 실기 로그는 `part 1/0`, 비정상 elapsed 196/398을 보였다. armer가 CPU
engine 끝 `$5E0D` 이후에 scheduler 상태를 썼지만, 같은 resident 호출의 renderer
고정 길이 복사가 그 꼬리까지 다시 덮었다. 따라서 count가 0이 되고 전환이 없었다.

0.4.6.39는 persistent 7 B를 slot 뒤/dir 전의 안전한 AC `$1F2710`으로 옮겼다.

```text
$1F2710 elapsed u16
$1F2712 part u8
$1F2713 count u8
$1F2714 next mini pointer u24
```

FEC4 scheduler는 channel1 문맥 8 B와 계산용 9 B를 스택에 보존하고, AC state를
읽어 계산한 뒤 AC에 다시 쓴다. CPU engine 꼬리는 상태 저장에 쓰지 않는다.
BIOS code는 2,085/2,957 B, 남은 bank1 여유는 872 B다. 시험 조합은
`0.4.6.39 + 0.5.64`; 0.4.6.38/0.5.63은 폐기한다.

##### 실기 PASS

0.4.6.39 + 0.5.64에서 D000 세 조각이 모두 정상 표시됐다.

```text
ARM    frame 6144  part 1/3  elapsed   0
PART   frame 6234  part 2/3  elapsed  90
PART   frame 6324  part 3/3  elapsed 180
END    frame 6542  part 3/3  elapsed 398
```

사용자 화면 확인도 `잘 나왔음`으로 PASS. frozen pack/전용 engine, LBA route,
mini 3 entries, AC-persistent frame scheduler, selector/stage 복원까지 연결이 닫혔다.
0.5.64 callback은 read-only이므로 자막 전환 자체는 BIOS 0.4.6.39의 동작이다.

#### 0.4.6.40 — frozen native 세트 Track24 선적재, 무Lua D000 시험판

0.4.6.39의 남은 Lua 역할은 frozen 정적 데이터 업로드뿐이었다. 0.4.6.40은
검증된 0.4.6.22 디스크를 기준으로 frozen `$6600` renderer를 교체하고, 아래 묶음을
Track24 끝에 추가하여 BIOS preload의 다섯 번째 행으로 `$1F2800`에 적재한다.

```text
bundle  build/cutscene_subs/adpcm_native_frozen_8F20AF38.bundle.bin
bytes   41,869
base    $1F2800
dir     $1F2800  5,412 B
payload $1F3D24 26,252 B
master  $1FA400  9,414 B
engine template $1FC900 653 B, frozen/$6600
active renderer $1F1F00 653 B, frozen/$6600
scheduler state $1F2710 7 B
```

고정 4행이던 BIOS preload 호출은 Y가 8씩 증가하는 loop로 바꿔 5행을 지원한다.
loader는 263/272 B이며, native dispatcher/scheduler는 0.4.6.39와 같은 2,085 B다.
Track24를 다시 역추출해 bundle/renderer가 원본과 byte-exact임을 확인했고, Track02는
0.4.6.22와 byte-exact로 보존됐다. BIOS `$FEC4 -> JSR $FFD4`와 bank1
`$FFDA -> JMP $F0EA`도 확인했다.

```text
folder build/patch/0.4.6.40
BIOS   Syscard3_galmuri_0.4.6.40.pce
CUE    Snatcher CD-ROMantic (Japan) [KO].cue
Lua    사용하지 않음
test   Power Cycle 후 D000에서 0/90/180f 세 조각 정상 표시 확인
```

이 판의 다음 판정은 실기 무Lua PASS 여부다. PASS 뒤에는 D000 `$003083` 하드코드를
전체 ADPCM route로 일반화하고, 마지막에 이미 완료된 CD-DA native 경로와 병합한다.

##### 0.4.6.40 실기 FAIL — preload loop의 Y 비보존

실기에서 부팅이 끝나지 않았다. 5행 loader를 줄이면서 `load_one`이 table offset Y를
8 증가시킨 뒤 `$BE64 LOAD_BLOB`도 Y를 보존할 것이라고 잘못 가정했다. 기존 4행
코드는 호출마다 `LDY #상수`를 다시 실행했기 때문에 LOAD_BLOB의 Y 반환값에 의존하지
않았다. 첫 호출 뒤 깨진 Y로 다음 table 행을 읽는 것이 무한 부팅의 원인과 일치한다.
0.4.6.40은 사용하지 않는다.

#### 0.4.6.41 — LOAD_BLOB 전후 Y 보존

`load_one`을 아래처럼 고쳤다. 이 시점에는 PLY가 N/Z 플래그도 바꾼다는 점을
놓쳤으므로 결과적으로 불완전한 수정이었다.

```text
$FF99  PHY
        JSR $BE64
        PLY
        RTS
```

loader는 265/272 B로 7 B가 남는다. frozen bundle/renderer 역추출, Track02 byte-exact
보존, `$FEC4` 및 bank1 dispatcher 훅을 다시 검증했다. 시험은 `build/patch/0.4.6.41`
에서 Power Cycle 후 Lua 없이 수행한다.

##### 0.4.6.41 실기 FAIL — PLY가 성공 플래그를 파괴

실기에서 로딩이 평소의 약 10배로 길어지고 타이틀이 나오지 않았다. LOAD_BLOB가
A=0/Z=1로 성공해도 `PLY`가 복원된 Y=$08을 기준으로 Z=0을 만들었다. 직후 `BNE
load_failed`가 성공을 실패로 오판하여 완료 state를 발행하지 않았고, 다음 CD_READ가
약 1.46 MB preload 전체를 반복했다. 증상과 코드가 일치한다. 0.4.6.41은 사용하지
않는다.

#### 0.4.6.42 — Y 보존 후 LOAD_BLOB 결과 플래그 복원

PLY 뒤 `CMP #0`을 추가했다. A는 LOAD_BLOB의 반환값이 그대로 남아 있으므로 성공은
Z=1, 실패는 Z=0으로 다시 만들어 기존 `BNE load_failed` 규약을 보존한다.

```text
$FF99  PHY
        JSR $BE64
        PLY
        CMP #$00
        RTS
```

loader 267/272 B(여유 5 B). 위 opcode열, frozen bundle/renderer 역추출, Track02 보존,
BIOS 두 훅을 모두 검증했다. 시험판은 `build/patch/0.4.6.42`, Power Cycle 후 Lua를
사용하지 않는다.

##### 0.4.6.42 preload 실기 PASS — 0.5.65 read-only 측정

추측을 중단하고 `lua/SUB/0.5.65.lua`로 loader 각 지점을 관찰했다. 실기에서 타이틀
부팅에 성공했고 아래 수치가 확인됐다.

```text
PRELOAD_BEGIN  1회                         frame 134
row            1, 2, 3, 4, 5 각 1회
LOAD_BLOB      in/out/result 각 5회
return A       다섯 행 모두 $00
restored Y     $08, $10, $18, $20, $28
publish        6회
state AC       AC 15 51 00 01 02
bundle head    00 30 6B 24 3D 1F
preload done   frame 2635 (약 41.7초)
```

따라서 긴 최초 부팅은 반복 로딩이 아니라 기존 translation 1.23 MB를 포함한 다섯
payload의 실제 선적재 시간이다. 첫 행만 frame 134→2238(약 35초)이 걸렸으며 전체
preload 재시작은 없었다. 0.4.6.42의 BIOS preload/완료 guard/native bundle 적재는
실기 PASS로 닫는다. 다음 판정은 Lua 업로드 없이 D000 세 조각 표시가 정상인지다.

##### 0.4.6.42 무Lua D000 최종 실기 PASS

타이틀, 첫 화면, 접수처까지 정상 진행한 뒤 D000 자막 1/2/3 조각이 모두 정상
출력됐다. `0.5.65.lua`는 loader를 읽기만 하는 측정판이며 AC 업로드·자막 state·
renderer를 변경하지 않는다. 따라서 아래 전체 경로가 BIOS/Track24만으로 동작한
것이 확인됐다.

```text
Track24 frozen pack/engine/native table preload
  -> ADPCM LBA $003083 native route
  -> mini 3-entry 설치
  -> state $02 native arm
  -> AC $1F2710 scheduler
  -> part 1/3 @ 0f
  -> part 2/3 @ 90f
  -> part 3/3 @ 180f
  -> 정상 종료
```

사용자 실기 판정: `1, 2, 3 정상 출력 성공`. D000 한정 ADPCM 자막의 정적 데이터
업로드와 런타임 스케줄링은 모두 네이티브화 완료다. 다음 단계는 새 렌더러를 만들지
말고, `$003083` POC 제한을 제거하여 기존 1,046개 ADPCM master/native route 전체에
같은 검증된 경로를 일반화하는 것이다. 효과음 분류는 사용자가 명시한 항목만
효과음으로 유지한다.

#### 0.4.6.43 — 실기 PASS 두 경로 통합 후보 (정적 PASS, 실기 미판정)

전체 ADPCM 일반화보다 CD-DA 결합을 먼저 한다. 이전 문서에서 확인한 정확한 CD-DA
성공 계보는 0.4.6.24 OUTPUT PASS, 0.4.6.25 state3 종료/복원 PASS다. 실패한
0.4.6.26/.27 결합 코드는 사용하지 않고, 0.4.6.25 detector와 671 B engine 계약만
0.4.6.42에 이식했다.

```text
folder      build/patch/0.4.6.43
BIOS        Syscard3_galmuri_0.4.6.43.pce
CUE         Snatcher CD-ROMantic (Japan) [KO].cue
Lua probe   lua/SUB/0.5.66.lua (read-only, 업로드/쓰기 없음)

CD-DA       Track raw $11 + ($263C|$2638) start pulse
             engine_cdda_state3_poc.bin 671 B
             AC template $1FD000 · active helper base $7900
             2188f 첫 줄 · 2435f 둘째 줄 · 2683f state3/소거

ADPCM       기존 D000 LBA $003083 route와 0/90/180f scheduler 그대로
             frozen engine 653 B + FF padding to 671 B
             AC template $1FC900 · active helper base $6600
```

active renderer 슬롯은 하나이므로 두 엔진을 동시에 두지 않는다. 시작 매체에 맞는
template을 AC `$1F1F00`에 복사하고 resident가 CPU `$5B80`에 싣는다. state 2에서
CPU `$5DDA`가 CD-DA timer 첫 opcode `$38`이면 CD-DA 엔진 자체 timer에 맡기고,
아니면 검증된 ADPCM AC scheduler를 실행한다. ADPCM 복원은 671 B 전체를 복사해
CD-DA signature가 잔류하지 않게 한다.

정적 검증:

```text
preload loader       267/272 B
integrated dispatcher 2326/2957 B (631 B free)
native bundle        43,679 B · 22 sectors
bundle/AD template/CD-DA template Track24 역추출 byte-exact
Track02              0.4.6.22와 byte-exact
BIOS FEC4/bank1 hook · CD-DA signature gate · track/pulse detector 확인

BIOS    5E63E0BEF3AE3085AA6BD5A2FCC570CEF07F625EABC48417EEC7F0666CA2DCD9
Track24 5F22882EF0D4346CFD9DE6653F218EA2C21131D52F63116BC16160301ECECA2C
bundle  BDB5AAB7A9581CCE468A73FEDEC323EC54EBE7105BFA669A149406B2EFCA56A8
```

실기 순서는 Power Cycle 후 0.5.66을 먼저 로드하고 0.4.6.43을 실행한다. 오프닝
Track 17에서 36.46/40.59초 두 줄과 44.72초 소거를 먼저 확인한 뒤, D000의 1/2/3
조각을 회귀 확인한다. 두 항목 전에는 0.4.6.43을 PASS로 적지 않는다.

##### 0.4.6.43 실기 FAIL — CD-DA CPU 엔진 교체 시점 오류, ADPCM은 정상

실기에서 CD-DA 자막은 나오지 않았고 ACT 1 첫 화면이 깨졌다. 반면 같은 합본의
ADPCM D000 자막은 1/2/3 조각 모두 정상 출력됐다. 따라서 frozen pack, ADPCM
native route, scheduler와 renderer는 보존됐으며 실패 범위는 CD-DA 전환부로
격리된다.

`0.5.66.lua` 측정에서는 Track 17 detector와 start pulse가 검출되고 active AC
helper도 `$7900`으로 교체됐지만, CD-DA elapsed가 0에서 진행하지 않았다. resident
state1 코드를 다시 대조한 결과 실행 순서는 아래였다.

```text
select/copy helper
verify current CPU engine
JSR current CPU engine ENTRY
copy active AC engine -> CPU $5B80
state 1 -> 2
```

0.4.6.25는 부팅 때부터 AC와 CPU가 모두 CD-DA 엔진이어서 이 계약을 만족했다.
0.4.6.43은 active AC만 CD-DA로 바꾸고 CPU에는 ADPCM 엔진을 남겼으므로, resident가
복사 전에 잘못된 ENTRY를 호출했다. 반복 start, elapsed 정지와 화면 손상이 이
실행 순서로 설명된다. 0.4.6.43은 사용하지 않는다.

#### 0.4.6.44 — resident 호출 전 CPU 엔진 동기화 후보

0.4.6.43의 나머지 구조는 유지하고, CD-DA 및 ADPCM arm 양쪽에서 active AC
`$1F1F00`의 671 B 엔진을 CPU `$5B80`에 먼저 복사한 뒤 state 1을 발행하도록
고쳤다. 이로써 resident의 선행 ENTRY 호출이 선택된 매체의 엔진을 실행한다.

```text
folder       build/patch/0.4.6.44
BIOS         Syscard3_galmuri_0.4.6.44.pce
CUE          Snatcher CD-ROMantic (Japan) [KO].cue
Lua probe    lua/SUB/0.5.67.lua (read-only)
dispatcher   2396/2957 B (561 B free)
```

0.5.67은 불안정한 endFrame `$7FDF` 관찰값을 판정에 쓰지 않는다. 실제 bank1의
CD-DA detector/start, ADPCM route/scheduler와 CPU engine ENTRY를 직접 관찰하며,
CD-DA elapsed 2188/2435/2683 및 ADPCM 조각 전환을 자동 기록한다. 시험 전에는
Lua를 먼저 로드하고 Power Cycle한다. 이 실기 측정 전까지 0.4.6.44는 후보이며
PASS가 아니다.

##### 0.4.6.44 실기 FAIL — 엔진 교체 성공, state가 다시 idle로 떨어져 5회 재무장

`0.5.67.lua` 실기 측정 결과 CPU 선복사 수정 자체는 성공했다. frame 4837의 첫
CD-DA start 직후 CPU engine signature가 `$38`로 바뀌고, helper는
`00 79 03 C8`, engine ENTRY도 실행됐다. ADPCM 자막은 계속 정상 출력됐다.

그러나 start pulse가 유지된 동안 CD-DA start가 frame 4837/4839/4841/4843/4845에
총 5회 실행됐다. 매번 elapsed는 0으로 돌아갔고 2188 frame 문턱에 도달하지
못했다. 즉 0.4.6.44는 이전의 wrong-engine 문제를 해결했지만, 첫 기동 후
resident state가 2에 머물지 않고 다음 idle 판정으로 떨어지는 별도 문제가 남았다.

다음 단계는 빌드를 늘리지 않고 `lua/SUB/0.5.68.lua`로 `$7FDF` write callback의
실제 writer PC/value, resident start/run/restore 분기와 `$5E1D-$5E1E` elapsed
writer를 측정하는 것이다. 이 결과가 나오기 전에는 pulse latch나 state 강제
유지 코드를 넣지 않는다.

##### 0.5.68 실측 — 정확한 종료 writer는 legacy BIOS `$FF06`

전체 TSV `cdda_state_writer_0_5_68_20260831_164838.tsv`에서 원인이 확정됐다.

```text
frame 4720  CDDA_START
            state $00->$01 at $F88E
            resident copy 후 $01->$02 at $7F75
frame 4721  $FF06가 $7FDF에 $03 기록
            resident restore가 $03->$00 at $7F7A
frame 4722  다음 pulse에서 다시 CDDA_START
```

이 순서가 pulse 동안 5회 반복됐다. `$FF06`은 기존 FEC7의 ADPCM active 종료
분기다. `$180D & $20`이 없으면 음성이 끝났다고 보고 state 3을 쓰는데, CD-DA는
그 ADPCM playing bit를 쓰지 않으므로 시작 다음 프레임에 즉시 종료됐다. 엔진,
helper 또는 renderer 손상이 원인이 아니다.

#### 0.4.6.45 — CD-DA/ADPCM active 의미 분리 후보

ADPCM 종료 판정은 그대로 보존하고 CD-DA active만 우회한다.

```text
dispatcher CD-DA active  state는 2로 유지, 반환 A만 $FC
legacy FEC7              $FC는 알려지지 않은 nonzero라 side effect 없이 반환
resident                 CMP #$02 -> BIT #$01 (C9 02 -> 89 01)
                         $02와 $FC는 모두 even이라 active/run
                         start $01과 restore $03은 odd라 기존 start/restore
```

resident 수정은 0.8.5 이미지의 offset +11, Track02 raw sector 254 한 곳이며 EDC/ECC를
재계산했다. dispatcher는 2404/2957 B(553 B free)다. 시험판은
`build/patch/0.4.6.45`, read-only 자동 판정은 `lua/SUB/0.5.69.lua`다. PASS 조건은
CDDA start 1회, `$FF06` legacyEnd 0회, elapsed 2188/2435/2683 도달이다. 이후 D000
ADPCM 1/2/3과 정상 종료도 회귀 확인해야 최종 PASS다.

##### 0.4.6.45 최종 실기 FAIL — 두 경로 모두 회귀

CD-DA 타이머와 자막 출력 자체는 성공했으나 ACT1 화면이 세로줄 형태로 깨졌다.
이어 확인한 ADPCM에서는 음성만 나오고 자막이 표시되지 않았으며, 음성 종료 뒤
UI 복귀도 실패했다. 따라서 0.4.6.45는 부분 성공이 아니라 통합판 전체 FAIL이다.

```text
CD-DA   active/timer/subtitle PASS · ACT1 화면 보존 FAIL
ADPCM   음성 PASS · 자막 FAIL · 종료/UI 복귀 FAIL
```

0.4.6.45에서 추가된 의미 변경은 두 곳이다. dispatcher가 CD-DA active를 `$FC`로
반환하고 Track02 resident의 `CMP #$02`를 `BIT #$01`로 바꿨다. 이 방식은 기존
resident/ADPCM restore 계약까지 바꾸므로 그대로 발전시키지 않는다. 환경 A에서 재개할
때는 0.4.6.42 ADPCM PASS 기준선과 0.4.6.25 CD-DA 별도 PASS 소스를 다시 나란히
놓고, 공용 state 의미를 바꾸지 않는 별도 CD-DA active 실행 경로를 측정·설계한다.

#### 0.4.6.46 — legacy active 루틴 자체 분기 후보 (실기 판정 전)

0.4.6.45의 `$FC` 반환과 resident `BIT #$01` 변경은 모두 폐기했다. Track02는
0.4.6.42와 SHA-256이 동일하며 resident/ADPCM 계약을 한 바이트도 바꾸지 않는다.
대신 BIOS legacy active 루틴 시작 `$FEFA`만 `JSR $FFD4 / RTS`로 연결한다.

- CD-DA 엔진 signature `$5DDA == $38`: `$180D`를 보지 않고 A=`$02` 반환
- ADPCM: 원래대로 `$180D & $20`이면 A=`$02`, 아니면 state=`$03`
- dispatcher 2445/2957 B, 512 B free
- BIOS SHA-256 `C848D35E35349FF4F7FBF0036B1A0A005798BD822349E6B8F5FFDA660D157231`
- 빌드 `build/patch/0.4.6.46`
- 자동 read-only 판정 `lua/SUB/0.5.70.lua`

시험은 `0.5.70.lua`를 먼저 로드하고 Power Cycle한다. ACT1 화면, CD-DA
2188/2435/2683, ADPCM D000 1/2/3, 종료/UI 복귀가 모두 맞기 전에는 PASS가 아니다.

##### 0.4.6.46 실기 FAIL — CD-DA state 2 영구 점유와 X 파손

실기에서 ACT1 첫 화면이 깨졌고 CD-DA와 ADPCM 자막이 모두 나오지 않았다.
`native_combined_0_5_70_20260831_171343.tsv`는 실패 순서를 확정한다.

```text
f4716  CDDA_START 1회 · state 00 -> 01 -> 02
이후   legacyEnd 0회 (0.4.6.44의 즉시 state 3 문제는 제거됨)
       active hook/return2가 매 프레임 실행, 6000회 이상 누적
       CD-DA elapsed는 계속 0, 2188/2435/2683 모두 미도달
ADPCM  D000에 와도 CD-DA signature $38과 state 2가 남아 정상 arm 불가
```

즉 두 자막이 독립적으로 고장 난 것이 아니다. CD-DA가 state 2를 영구 점유해 종료와
후속 ADPCM 진입을 모두 막은 연쇄 실패다. 또한 새 FEFA 경로는 공용 dispatcher 첫
명령 `TSX`를 매 프레임 통과한다. 원래 FEFA active 함수는 X를 바꾸지 않으므로 이
ABI 파손이 ACT1 화면 깨짐의 직접 용의점이다. 0.4.6.46은 사용하지 않는다.

다음 재개 시에는 새 빌드 전에 read-only probe로 `$7F82` resident run, `$5B83`
engine entry, `$5E1D-$5E1E` writer PC를 함께 측정한다. FEFA를 공용 dispatcher로
보내는 방식은 폐기하고, X/Y 보존과 CD-DA timer 호출 계약을 별도 짧은 경로에서
검증해야 한다.

#### 0.4.6.47 — `$5B80` 단일 소유 overlay 후보 (정적 PASS · 실기 대기)

과거 문서와 `0.5.72` 실측을 다시 대조했다. `$5B80-$5E1E`는 영구 빈 공간이 아니라
음성 구간에만 빌리는 게임 레코드 캐시다. 정상 `.42`의 Track 17 후반 frame 9399에서
게임 PC `$7064/$713F/$71A1`이 실제 머리 `82 FF FF 01 3E 00 00 82`를 읽었다.
0.3.8에서도 이 레코드를 지웠을 때 새 게임 화면이 같은 계열로 깨진 전례가 있다.

다만 `.25` CD-DA와 `.42` ADPCM이 각각 실기 PASS했으므로 주소를 옮기는 것이 답은
아니다. 성공 계약은 `$5B80`을 한 매체가 시간제로 빌리고 종료 시 resident helper가
반납하는 overlay다. 최근 합본은 bank1 판정 뒤 `$FEC7`의 legacy ADPCM 판정을 다시
실행해 이 계약을 깨뜨렸다.

`.47`의 구조:

```text
resident JSR $FEC4
  -> JSR $FFD4 (bank1 완결 판정)
     state 0: ADPCM LBA 또는 CD-DA track/pulse 중 하나만 arm
     state 2 CD-DA: renderer의 STX $7FDF 종료를 기다림
     state 2 ADPCM: scheduler + 기존 $180D bit20 종료
  -> $FEC7 RTS로 resident에 직접 복귀 (legacy 이중 판정 없음)

state 1 resident 순서
  copy helper -> helper ENTRY(save/setup) -> 선택 renderer copy -> state 2
```

CPU `$5B80` 선복사는 제거했다. Track02 resident와 state 0/1/2/3 의미는 `.42`와
바이트/동작 계약을 바꾸지 않았다.

```text
build       build/patch/0.4.6.47
BIOS        Syscard3_galmuri_0.4.6.47.pce
Lua         lua/SUB/0.5.73.lua (read-only · 자동 기록)
dispatcher  2386/2957 B (571 B free)
BIOS SHA    83EFDC1EA52F53889BF00730038B7AEA718B068E8BFE6C103D41EC36E9CA6C14
CDDA engine 101E3A607CBCBF8ACB95E5485616D524F9EEC96841F0E523F4E28EBCBBE6852E
```

정적 감사 PASS:

```text
Track02 == 0.4.6.42 byte-exact
FEC4 bytes = 20 D4 FF 60
CPU $5B80 renderer pre-copy signature 없음
CD-DA engine pack = frozen 8F20AF38...
CD-DA finish STX $7FDF 있음
```

실기 판정 순서는 화면 무손상 -> CD-DA 36.46/40.59/44.72 -> 게임 레코드
`82 FF FF 01 3E 00 00 82` 반납 -> D000 1/2/3 및 UI 복귀다. 아직 실기 전이므로
PASS로 승격하지 않는다.

##### 0.4.6.47 실기 FAIL — 반환 A는 0이지만 Z가 복원되지 않음

타이틀 화면이 뜨지 않았다. `0.5.73` 로그에서 CD-DA start는 0회인데 resident
`$7F7A`가 매 프레임 state 0을 다시 쓰고 있었다. 이는 restore 분기가 매 프레임
실행됐다는 뜻이다.

원인은 bank bridge의 `PLP`다. dispatcher가 A=0을 반환해도 `PLP`가 호출 전 flags를
복원하고, `.47`의 `$FEC7 RTS`는 Z를 다시 만들지 않았다. 따라서 resident의 첫
`BEQ done`이 A=0이 아니라 오래된 Z를 보고 restore로 빠졌다. 매 프레임 helper
restore가 실행되어 타이틀 스프라이트가 망가졌다. `.42` preload의 `PLY / CMP #0`
수정과 같은 종류의 ABI 결함이다.

#### 0.4.6.48 — 반환 Z 복원 후보 (정적 PASS · 실기 대기)

`.47`에서 딱 반환 꼬리만 바꿨다.

```asm
$FEC4  JSR $FFD4
$FEC7  CMP #$00       ; 반환 A로 Z 재생성
$FEC9  RTS
```

dispatcher, Track02 resident, frozen pack/engine, state 계약과 CPU 선복사 제거는 `.47`과
동일하다. 측정기는 `lua/SUB/0.5.74.lua`이며 `.73`의 state 로그 폭주 조건도 함께
고쳤다.

```text
build     build/patch/0.4.6.48
BIOS SHA  395F98AAA3C54A978084B865C6A00D5832A8A827BE4034BEFBEE41AA66F33602
FEC4      20 D4 FF C9 00 60
```
