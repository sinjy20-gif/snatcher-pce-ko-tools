# 환경 B용 짐 — CD-DA 스케줄러 자리 문제 (2026-09-04)

전제: 어젯밤 문서 `SNATCHER_CDDA_SCHEDULER_2026-09-03_EVENING.md` 를 먼저 읽었다고 본다.
이 문서는 그 §6-2 "케이브 예산 초과" 를 어떻게 푸는지만 다룬다.

## ★ 읽는 순서

```
§9   0.4.7.2 를 끝까지 구웠다.  지금 상태는 여기다   ★먼저 읽을 것
§8   자리 결정 (뱅크 $ECF9).  §3 의 정정본
§7   뱅크1 여유 실측 (386 B 가 아니라 1,938 B)
§1·2·4  그대로 유효
§3·5    ★폐기.  기록으로만 남긴다
```

### 오늘 만든 것

```
신설
  tools/measure_cdda_bank_budget.py        예산 측정.  읽고 재기만 한다
  tools/verify_adpcm_untouched.py          ★ ADPCM 무변경 증명기
  tools/patch_bios_cdda_scheduler.py       스케줄러를 $ECF9 에 심는다
  tools/build_snatcher_0_4_7_2_cdda_scheduled.py   최상위 빌드
  lua/SUB/0.5.165-borrow-tail-alive.lua    프로브.  순수 관측

고침 (전부 **opt-in**.  켜지 않으면 지금까지와 바이트까지 동일)
  build_snatcher_0_4_6_43_cdda_adpcm.py    CDDA_MINI_INDEX · CDDA_SCHEDULER_AT
  build_snatcher_0_4_6_29_native_arm.py    cdda_mini_ac · cdda_scheduler_at
  build_subtitle_engine_cdda_scheduled.py  매체 지문 꼬리 ($CD @ +670)
  build_snatcher_cdda_scheduler.py         origin 을 인자로
```

**ADPCM 은 한 바이트도 안 바뀐다** -- `verify_adpcm_untouched.py` 가 매 빌드 증명한다.

### ADPCM 무변경 증명기 -- CD-DA 를 고칠 때마다 돌릴 것

```
python tools/verify_adpcm_untouched.py --snapshot     ★기준선 (이미 떠 뒀다)
python tools/verify_adpcm_untouched.py                고친 뒤 매번
```

```
검사 1  CD-DA 를 통째로 끈 디스패처가 기준선과 바이트까지 같은가  (엄밀)
        -> 여기가 변하면 편집이 ADPCM 으로 샌 것이다
검사 2  실제 디스패처의 ADPCM 라벨 블록 길이가 전부 그대로인가    (구조)
        -> 길이가 같다 = 명령이 늘지도 줄지도 않았다.  주소만 밀린 건 정상
```

2026-09-04 기준선: 태그 `D8723DEE` · CD-DA 끈 판 2,323 B · 실제 판 2,571 B ·
ADPCM 라벨 57 개.  **지금 상태로 검사 1·2 통과 확인.**

---

## 0. 한 줄 요약  ★ 최종본은 §8 이다

```
뱅크1 여유는 386 B 가 아니라 1,938 B 였다 (BANK1_FREE 가 빈 자리의 일부만
청구하고 있었다 -- §7).  그래서 스케줄러 467 B 를 **아직 아무도 안 쓰는
뱅크1 구간**에 그냥 놓는다.

권하는 자리   bankA  $ECF9-$F04D  853 B   감사 네 항목 전부 깨끗
BANK1_FREE    386 B 중 73 B 만 쓴다 (cdda_start delta 63 + 분기 10)
ADPCM         한 바이트도 안 건드린다 (verify_adpcm_untouched.py 로 매번 증명)
```

⚠ **§3 은 폐기됐다** (빌린 RAM 꼬리 537 B 는 실제로 89 B 였다).  §8 을 볼 것.
  §1·§2·§4 는 그대로 유효하다.

---

## 1. 어제 막힌 지점과, 오늘 재서 알아낸 것

배포 사슬과 같은 인자로 armer 를 재조립해서 쟀다 (`measure_cdda_bank_budget.py`).
결과 2,571 B 는 `build/patch/0.4.7.1/manifest.json` 의 `native_dispatcher_bytes`
와 **정확히 일치**한다.

★ 이 도구는 **태그를 안 맞추면 틀린 json 을 먹는다.**  배포판은 태그
  `D8723DEE` (selector +379) 를 썼는데 기본값은 `frozen_8F20AF38` (+367) 이다.
  길이는 같아 예산 수치는 안 흔들리지만 피연산자가 어긋난다.
  `verify_adpcm_untouched.py` 는 팩에서 태그를 재서 자동으로 맞춘다 -- 그쪽을 볼 것.

★ 태그를 맞춰도 배포 이미지와 **15 바이트**가 남는다.  이건 정상이며 §7 이 정체다
  (빌드 뒤 `patch_bios_cpu_cache.py` 후처리).

```
뱅크1 여유        $F0EA-$FC76  2,957 B 중 2,571 B 사용  ->  남은 자리 386 B
현재 cdda_start   $F847-$F919  211 B      ★ 이미 뱅크에 있다
```

어제 문서는 "cdda_start 재작성분도 386 B 를 나눠 써야 한다" 고 봤지만,
재작성은 **있는 것을 고치는 일**이라 예산에 청구되는 건 늘어나는 몫뿐이다.

```
엔진 복사 671 B -> 615 B    delta +0   ★ 페이지 수가 둘로 같아 코드가 안 변한다
AC_SCHED 초기화             +63 B
mini index 런타임 복사      +80 B      <- 안 해도 된다 (§2)
```

---

## 2. AC 로 옮기는 것 ① — mini index 는 복사할 필요가 없다

ADPCM 이 mini index 를 런타임에 복사하는 건 **음성마다 항목이 다르기** 때문이다.
CD-DA 트랙 17 은 39 항목이 빌드 때 확정돼 있다.  그러면
`build_snatcher_0_4_6_40_native_preload.py` 의 `make_bundle()` 에 행 하나만
더하면 된다 -- 그 함수는 (주소, 블롭) 을 임의로 받고 겹침 검사까지 한다.

```
자리    AC $1FEB00   507 B
효과    뱅크 코드 -80 B.  스케줄러는 AC_SCHED.next 를 그 주소로 여는 것뿐
```

### AC 할당 지도 (소스 전수 grep, 2026-09-04)

```
$1C0000  lifecycle 백업 (POC)
$1EF000  AC_MINI            ADPCM mini index (런타임 복사 대상)
$1F1C00  헬퍼 · +436 이 제어블록 ($1F1DB4)
$1F1F00  AC_ENGINE          active 엔진 슬롯
$1F2700  AC_SLOT            관측 슬롯
$1F2710  AC_SCHED           7 B  (elapsed u16 · part · count · next u24)
$1F2800  AC_DIR + payload
$1FB800  AC_MASTER
$1FE400  AC_ENGINE_TEMPLATE  ADPCM 원본 671 B  -> $1FE69F
$1FE800  AC_CDDA_TEMPLATE    CD-DA 원본 671 B  -> $1FEA9F
$1FFDC0  ac_readthrough RESET_AT
$1FFFF0  ac_readthrough STATE_BASE

★ 자유 구간   $1FEAA0 - $1FFDBF   약 4,896 B
```

게임은 Arcade Card 를 안 쓴다 (Super CD-ROM² 타이틀).  AC 를 건드리는 건 우리
코드뿐이므로 위 표가 전부다.  그래도 프로브가 실측으로 검산한다 (§5).

---

## 3. ~~AC 로 옮기는 것 ② — 스케줄러도 뱅크에 상주시키지 않는다~~  ★폐기

> ⚠⚠ **이 절은 틀렸다.  따르지 말 것.  §8 이 정정본이다.**
> 아래는 "$5DE7-$5FFF 537 B 가 비어 있다" 를 전제로 썼는데, 그 구간에는
> `$5E40` 선적재 루틴이 살아 있다.  실제로 쓸 수 있는 건 89 B 뿐이라
> 스케줄러 467 B 가 안 들어간다.  기록으로만 남긴다.

렌더러는 이미 이렇게 돌고 있다 -- AC 에 원본을 두고,
음성/CD-DA 가 시작될 때만 빌린 RAM 으로 복사해 거기서 실행한다.
스케줄러도 똑같이 하면 된다.

### 빌린 RAM 계약 (이미 확인된 것)

```
$5B80-$5E3F    704 B   지금 배포 경로가 쓰는 범위 (스크립트 VM 데이터 스택)
$5B80-$5FFF  1,152 B   lifecycle POC 가 AC $1C0000 저장/복원으로 빌렸던 범위
                       (tools/build_bios_subtitle_lifecycle_poc.py:43
                        RAM_LO, RAM_BYTES = 0x5B80, 0x480)
```

### 배치

```
$5B80 - $5DE6    615 B   CD-DA 렌더러 (engine_cdda_scheduled_track17)
$5DE7 - $5FFF    537 B   ★ 비어 있는 꼬리  <- 여기에 스케줄러
```

스케줄러는 467 B (TAI 최적화 판) 또는 505 B (fallback, §4) 다.  **둘 다 들어간다.**

### 뱅크1 비용

```
cdda_start  AC_SCHED 초기화                        +63 B
            스케줄러 코드 복사                      +35 B
              ac_ptr_const(0, AC_SCHED_CODE) 28 + TAI 7
              (AC -> CPU RAM 이므로 TAI 한 방이면 된다)
            mini index                              +0 B   (선적재)
            엔진 복사 671->615                      +0 B
매체 분기   scheduler_cdda 호출을 RAM 주소로        ~10 B
-----------------------------------------------------------
총                                                 108 B
뱅크1 여유                                          386 B
★ 남는 자리                                        278 B
```

### 덤으로 딸려 오는 것

```
· ADPCM 은 한 바이트도 안 바뀐다 (소유자 요청 그대로)
· 어제 검토하던 "AC 포인터 꼬리 헬퍼"(ADPCM 코드를 건드려야 했다) 가 불필요해진다
· 앞으로 CD-DA 쪽 코드가 커져도 뱅크가 아니라 RAM 꼬리 537 B 를 먹는다
```

### 새 AC 배치

```
$1FEB00   mini index     507 B   -> $1FECFA
$1FED00   스케줄러 코드  467 B   -> $1FEED2
둘 다 자유 구간 $1FEAA0-$1FFDBF 안이다
```

---

## 4. TAI 자동증가 가정은 이제 설계를 가르지 않는다

어제 문서가 1 순위로 꼽은 미검증 가정 -- "TAI 전송 직후 AC 자동증가가 이어진다".

**정황은 상당히 좋다.**  배포 중인 0.4.7.1 이 이미 `TAI $1A10 -> $5CFB, 9`
($FA08) 와 `TAI $1A10 -> $5D99, 31` ($FA2B) 로 AC 데이터 포트를 블록 전송하고
있고, 그게 **연속된 바이트로 제대로 도착한다** (ADPCM 자막이 정상 동작).
`$1A?0`/`$1A?1` 은 같은 데이터 레지스터의 두 미러이므로 (`build_ac_dynamic_0_1_14.py:109`,
`SNATCHER_UI_FLICKER_HANDOFF_2026-08-14.md:40`), 9 바이트가 연속으로 왔다는 건
**미러 접근에서도 포인터가 매번 증가한다**는 뜻이다.

남는 미지는 하나뿐이다: "블록 전송이 끝날 때 포인터가 리셋되지 않는다".
그런 기전은 알려진 게 없지만 관측된 적도 없다.

★ 그런데 **틀려도 이제 안 막힌다.**

```
fallback   ac_ptr_local 한 번 더 (+38 B)  ->  스케줄러 505 B
RAM 꼬리   537 B                          ->  ★ 그래도 들어간다
```

그러니 확인은 하되 **환경 B 작업의 블로커가 아니다.**  순서를 뒤로 미뤄도 된다.

---

## 5. 환경 B에서 할 일

### 5-1. ★ 프로브 (이게 유일한 블로커)

```
lua/SUB/0.5.165-borrow-tail-alive.lua      0.4.7.1 에 올린다
산출물  C:/snatcher/dump/borrow_tail_0_5_165_<시각>.tsv
```

두 가지를 동시에 본다:

```
1  $5DE7-$5FFF 의 read / write / exec 가 0 인가      ★ §3 설계의 전제
   ($5E40 = 게임 선적재 루틴 NORMAL_PRELOADER 이 이 안에 있다.
    lifecycle POC 는 저장/복원으로 피했지만 배포 경로는 그냥 덮는다)
2  AC $1FEB00 을 아무도 안 여는가                     §2 의 전제
```

⚠ **오프닝만 보고 끝내면 안 된다.**  "안 건드린다" 를 증명하려는 것이므로
   오프닝(트랙 17) · 대사 장면 · 메뉴 · 장면 전환까지 돌려야 의미가 있다.
   화면에는 아무것도 안 그린다 (판정을 가리지 않으려고).

### 5-2. 결과에 따른 갈래

```
꼬리 0        -> §3 그대로 간다.  뱅크 108 B 만 쓴다
꼬리 접촉 O   -> TSV 의 PC 를 본다
                 (가) 접촉이 STATE==2 밖에서만 -> 재생 중엔 죽었다.  그대로 간다
                 (나) STATE==2 중에도 접촉      -> 꼬리를 $5E40 앞까지로 줄여
                     $5DE7-$5E3F (89 B) 만 쓸 수 있다 -> 스케줄러가 안 들어간다
                     -> 그때는 어제 문서 §10-4 의 "AC 포인터 꼬리 헬퍼"
                        (+222 B, 단 ADPCM 코드를 건드림) 로 되돌아간다
$1FEB00 접촉  -> 자유 구간 안 다른 자리로 옮기면 된다 ($1FEAA0-$1FFDBF 4.8 KB)
```

### 5-3. 프로브가 통과한 뒤 (순서)

```
1  make_bundle() 에 mini index 행 추가                    (§2)
2  스케줄러를 RAM 꼬리 origin 으로 다시 조립               build_snatcher_cdda_scheduler.py
     지금은 origin 0xF000 으로 재고만 있다 -> $5DE7 로 바꾼다
3  스케줄러 코드도 make_bundle() 행으로 추가 ($1FED00)
4  cdda_start 재작성 (+98 B) · 매체 분기를 RAM 주소로 (+10 B)
5  빌드사슬 (어제 문서 §7-1) 에 scheduled 경로 끼워넣기
6  TAI 가정 확인 (블로커 아님, §4)
```

---

## 6. 아직 안 푼 것 · 섞지 말 것

```
· 스케줄러를 RAM 에서 실행하면 **PC 상대 분기 거리**가 다시 잡힌다.
  지금 초안은 origin 0xF000 기준으로 트램폴린을 배치해 놨다 (어제 문서 §6-2).
  $5DE7 로 옮기면 크기는 같지만 라벨을 다시 풀어야 한다 -- 2-pass 가 잡아 준다
· 스케줄러를 부르는 쪽은 **엔진이 올라와 있을 때만** 불러야 한다.
  이미 있는 STATE==2 + CD-DA 지문 검사로 막힌다 (어제 문서 §5-0-1)
· "count 다 쓰면 STATE=3" 은 즉시 쓰지 않는다.  ready 기반 2 단 지연을 탄다
  (어제 문서 §5-0-1).  이건 설계가 바뀌어도 그대로다
· 자막 꼬리 오역 198 행 (어제 문서 §8-1) 은 소유자가 직접 닫았다.  종결
```

---

## 7. ★★ 뱅크1 여유는 386 B 가 아니었다 (같은 날, 회귀 도구 만들다 발견)

`verify_adpcm_untouched.py` 의 검사 3 이 배포 이미지와 15 바이트 차이를 냈다.
정체는 **빌드 뒤 후처리**였다 -- `patch_bios_cpu_cache.py` 가 반복되는
`LDA $7FDF` / `LDA #$01 STA $7FDF` 를 `$FC7A` 의 공용 서브루틴 호출
(`JSR` + `NOP NOP`)로 접는다.  그 루틴을 **`$FC7A-$FFD9` 864 B 라는 별도
빈 자리**에 놓고 있었다.

즉 `BANK1_FREE`($F0EA-$FC76) 는 뱅크1 의 빈 자리 **전부가 아니었다.**

### 7-1. 원본 BIOS 기준 뱅크1 의 FF 연속 구간

```
$ECF9-$FC76   3,966 B      <- BANK1_FREE 는 이 중 $F0EA 부터만 썼다
$FC7A-$FFFF     902 B
합계          4,868 B
```

### 7-2. 지금(0.4.7.1) 실제로 남아 있는 자리

```
$ECF9-$F04D    853 B   ★ 아무도 청구 안 함.  $F04E 부터는 EXIT_BRIDGE 등 살아있는 코드
$FAF5-$FC76    386 B      BANK1_FREE 의 남은 꼬리 -- 지금까지 세던 그 386 B
$FD1F-$FFD9    699 B   ★ patch_bios_cpu_cache 가 165 B 쓰고 남은 자리
------------------------------------------------------------------
합계         1,938 B
```

### 7-3. 프로젝트 감사 도구로 걸러 본 결과

```
python tools/audit_bios_free_space.py 0.4.7.1 <lo> <hi> --bank 1
```

대조군(살아 있다고 아는 자리 셋)이 CDL 에 전부 찍혀 있어 **CDL 을 믿을 수 있는
상태**에서 잰 것이다.

```
$ECF9-$F04D  853 B    이미지 FF 853/853 · 실행 0 · 데이터 0
                      직접 참조 0 건 ★ · 워드 5 건($F000/$F001/$F008/$F010 --
                      주소라기보다 데이터로 보인다)
                      -> 가장 깨끗하다

$FD1F-$FFD9  699 B    이미지 FF 699/699 · 실행 0 · 데이터 0
                      직접 참조 1 건 ($E86B JSR $FE92) · 워드 96 건
                      (값이 $FF00/$FE7C/$FEFE -- 뱅크 0 의 BIOS 점프표 모양이다.
                       뱅크 0 대상이면 오탐이지만 **아직 안 갈랐다**)
                      -> 대신 ★바로 앞 $FC7A-$FD1E 에 우리 코드가 이미 출하돼
                        정상 동작 중이다.  실전으로 검증된 이웃이라는 강점이 있다
```

⚠ 둘 다 **아직 승격하지 않았다.**  CDL 은 가 본 장면만 기록한다.  쓰기로 정하면
  그 전에 `$E86B JSR $FE92` 가 뱅크 0 대상인지부터 가를 것.

### 7-4. 그래서 무엇이 달라지나

```
· §3 설계(스케줄러를 AC->빌린 RAM)는 그대로가 낫다.  뱅크 108 B 면 충분하고
  1,938 B 를 손도 안 댄 채로 남긴다
· 하지만 "자리가 없어서 못 한다" 는 더 이상 사실이 아니다.
  어제 문서가 기각한 안들(뱅크 상주 스케줄러 540 B 등)도 자리로만 보면 들어간다
· §5-2 의 갈래 "꼬리가 살아 있으면" 에 선택지가 하나 더 생겼다:
  ADPCM 코드를 건드리는 §10-4 헬퍼로 가지 말고 $FD1F-$FFD9 를 승격하면 된다
```

---

## 8. ★★★ §3 정정 — 빌린 RAM 꼬리는 537 B 가 아니라 89 B 다

**§3 을 그대로 따르지 말 것.**  같은 날 코드를 짜다가 전제가 틀린 것을 찾았다.

### 무엇이 틀렸나

§3 은 `$5B80-$5FFF` 1,152 B 에서 렌더러 615 B 를 빼면 `$5DE7-$5FFF` 537 B 가
비어 있다고 봤다.  **비어 있지 않다.**

```
extraction/patch/static/build_ac_dynamic_0_1_14.py:17
  "...rebuilds the byte-identical 704-byte payload into the existing
   $5B80-$5E3F cache, so the verified 0.3.0-uitest BODY/UI renderer,
   ★the $5E40 preloader★, the $7F50 font wrapper and the $66E5 hook
   are all untouched."
```

```
$5B80-$5E3F   704 B   대사 레코드 캐시 (RECORD_BYTES = 704 · CACHE_BASE = $5B80)
$5E40         ★      선적재 루틴.  "untouched" 로 명시된 살아 있는 코드
```

lifecycle POC 가 `$5B80-$5FFF` 를 빌릴 때 **AC $1C0000 으로 저장/복원을 한 이유가
바로 이것이다.**  나는 그 저장/복원을 "조심성" 으로 읽었는데 실은 **필수**였다.

저장/복원 없이 쓸 수 있는 건 렌더러 뒤 `$5DE7-$5E3F` **89 B** 뿐이다.
스케줄러 467 B 는 378 B 초과 -- 안 들어간다.

### 그래서 어디로 가나 — 뱅크로 되돌아온다.  단 다른 구간으로

§7 에서 뱅크1 여유가 386 B 가 아니라 **1,938 B** 임이 밝혀졌으므로,
스케줄러를 그냥 뱅크에 상주시켜도 된다.  `BANK1_FREE` 꼬리(386 B)를 건드리지
않고 **아직 아무도 안 쓰는 구간**에 놓는다.

```
python tools/build_snatcher_cdda_scheduler.py       세 자리를 다 재 본다

[bankA] $ECF9-$F04D  853 B   467 B 들어간다 (여유 386 B)   ★감사 최상
        실행 0 · 데이터 0 · 직접참조 0 건
[bankB] $FD1F-$FFD9  699 B   467 B 들어간다 (여유 232 B)   실전 이웃
        실행 0 · 데이터 0 · 직접참조 1 건 ($E86B JSR $FE92 · 뱅크 미분류)
        단 바로 앞 $FC7A 에 우리 코드가 이미 출하돼 돌고 있다
[ram]   $5DE7-$5E3F   89 B   ★378 B 초과.  탈락
```

### 새 뱅크1 비용

```
sched_due_cdda      467 B   <- bankA 또는 bankB 에 (BANK1_FREE 와 별개 구간)
cdda_start delta     +63 B  <- BANK1_FREE 꼬리 386 B 에서 쓴다
매체 분기            ~10 B
스케줄러 코드 복사    +0 B   ★ 뱅크 상주이므로 복사가 필요 없다 (§3 의 +35 B 소멸)
```

```
BANK1_FREE 꼬리   386 B 중 73 B 사용  ->  313 B 남음
bankA 또는 bankB  467 B 사용         ->  386 또는 232 B 남음
```

### §3 대비 잃는 것 · 얻는 것

```
잃는 것   "CD-DA 코드가 커져도 뱅크를 안 먹는다" 는 이점이 사라진다
          AC->RAM 복사 구조의 우아함도 사라진다
얻는 것   빌린 RAM 의 저장/복원 문제를 통째로 피한다
          복사 단계가 없어져 cdda_start 가 더 단순해진다
          origin 만 바꾸면 되므로 스케줄러 본체는 한 줄도 안 바뀐다
```

### 프로브(§5-1)는 어떻게 되나

`$5DE7-$5FFF` 를 보던 목적은 사라졌지만 **버리지 말 것.**  두 가지로 여전히 쓴다:

```
1  AC $1FEB00 접근 여부 (mini index 선적재 전제) -- 그대로 유효
2  $5DE7-$5E3F 89 B 가 정말 죽었는지 -- 나중에 작은 것을 놓을 자리로 남는다
```

★ 대신 **새 1 순위 검증**이 생겼다:

```
bankA($ECF9) / bankB($FD1F) 중 고른 자리가 정말 죽었는가

  · CDL 감사는 이미 돌렸다 (§7-3).  둘 다 실행 0 · 데이터 0
  · 남은 것은 bankB 의 직접참조 1 건 -- $E86B 의 JSR $FE92 가
    뱅크 0 대상인지 뱅크 1 대상인지 가르는 일
  · bankA 를 고르면 그 건도 없어진다 (직접참조 0 건)
```

**그래서 지금 권하는 자리는 `bankA` ($ECF9-$F04D, 853 B) 다.**
감사 네 항목이 전부 깨끗한 유일한 후보다.

---

## 9. ★ 0.4.7.2 를 끝까지 구웠다 (2026-09-04)

프로브 없이 갈 수 있는 데까지 갔다.  **빌드가 통째로 나온다.**

```
python tools/build_snatcher_0_4_7_2_cdda_scheduled.py
python tools/patch_track24_subtitle_pack.py 0.4.7.2 --write
python tools/patch_bios_cpu_cache.py       0.4.7.2 --write
python tools/patch_bios_cdda_scheduler.py  0.4.7.2 --origin bankA --write   ★새 단계
python tools/verify_adpcm_untouched.py
```

### 9-1. 실측 결과

```
디스패처       2,571 -> 2,640 B   (+69 = AC_SCHED 초기화 63 + JSR 트램폴린 6)
BANK1_FREE     386 -> 317 B 남음
스케줄러       $ECF9 에 467 B     그 구간 853 B 중 386 B 남음
```

```
AC $1FE800   스케줄 연동 렌더러 671 B   [+670] = $CD   ★검산 통과
AC $1FE400   ADPCM 템플릿        [+670] = $FF   ★지문 충돌 없음
AC $1FEB00   mini index 507 B    원본과 바이트 동일  ★검산 통과
디스패처     JSR $ECF9  1 곳     ★검산 통과
```

### 9-2. ADPCM 무변경 증명

```
검사 1  CD-DA 를 통째로 끈 디스패처   2,323 B  바이트까지 동일   ✓
검사 2  ADPCM 라벨 57 개 블록 길이     변화 0 건                 ✓
```

`patch_bios_cpu_cache` 의 세 자리도 전부 정상이다 (주소만 밀렸다):

```
             0.4.7.1        0.4.7.2      이동
start_cdda   $F808    ->    $F80E        +6    (트램폴린)
start_adpcm  $F912    ->    $F957        +69   (트램폴린 + AC_SCHED)
entry        $F394    ->    $F394        0
```

### 9-3. 새로 만든 매체 지문

옛 지문(+602 의 `$38 SEC`)은 "ADPCM 이 그 자리에 마침 $38 이 아니다" 라는 우연에
기댔다.  스케줄 연동판은 타이머가 없어 그 자리 자체가 없다.

```
새 지문   +670 = $CD
근거      무장 코드가 슬롯을 max(adpcm, cdda) 만큼 ADPCM 템플릿 + FF 로 덮는다
          ADPCM 은 666 B -> +670 은 반드시 $FF.  우연이 아니다
가드      adpcm_bytes > 670 이면 빌드가 선다 (지문 자리를 덮으므로)
```

렌더러는 코드 615 B + FF 패딩 + 매직 = **671 B**.  옛 엔진과 크기가 같아
`cdda_start` 의 복사 루프가 한 바이트도 안 변한다.

### 9-4. ★ 아직 실기에 올리기 전에 확인할 것

```
1  뱅크 $ECF9-$F04D 가 정말 죽었나
   CDL 감사는 통과 (실행 0 · 데이터 0 · 직접참조 0).  실주행 무접촉은 미확인
   ★ 여기에 467 B 를 이미 심었다 -- 틀리면 그 장면에서 죽는다

2  AC $1FEB00 을 아무도 안 여나
   lua/SUB/0.5.165-borrow-tail-alive.lua 의 AC 페이지 지도로 본다

3  TAI 직후 AC 자동증가 (어제 문서 §6-2)
   틀리면 vram_base 가 엉뚱한 바이트에서 읽혀 화면이 깨진다
   -> 39 구간이 뜨긴 뜨는데 색/자리가 이상하면 여기부터 의심
```

### 9-5. 이 판이 처음 하는 일 (그래서 첫 판이 깨끗할 가능성은 낮다)

```
· 트랙 17 자막이 2 줄 -> 39 구간
· CD-DA 가 처음으로 blank_frame 보호를 받는다 (조각 전환, 어제 문서 §5)
· CD-DA 의 STATE=3 이 처음으로 ready 기반 2 단 지연을 탄다 (§5-0-1)
· 스케줄러가 구간마다 vram_base 즉치 3 개를 갈아끼운다 (ADPCM 은 무장 때 1 회)
```

깨지면 어디를 볼지는 위 순서대로다.
