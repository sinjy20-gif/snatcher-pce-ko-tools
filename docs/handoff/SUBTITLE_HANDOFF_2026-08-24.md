# 자막 인계 메모 — 2026-08-24

다른 컴퓨터에서 이어서 하려고 묶은 것이다.  이 파일 하나만 읽고 시작할 수 있게
썼다.  자세한 것은 같이 들어 있는 `SUB_docs/` 의 날짜순 문서를 볼 것.

> **문서는 날짜순으로 볼 것.**  이 프로젝트에서 앞 문서의 결론을 뒷 문서가
> 뒤집은 적이 여러 번 있다.  `0_CUTSCENE_SUBS` -> ... -> `6_LIVE` -> `7_DRAFT` 순이다.

---

## 0. 30 초 요약

자막은 **실기에서 이미 뜬다** (접수처 3 대사).  파이프라인은 다 이어져 있고,
지금 막혀 있는 것은 **글을 화면까지 이어 주는 열쇠 두 개**다.

```
되는 것    디스크 훅 · 상주부 · 엔진 · 팩 · 글꼴 · 조각 전환 · UI 복귀
막힌 것 1  ADPCM 열쇠가 이벤트를 구분 못 한다  -> 대사 56 중 31 이 팩에서 빠진다
막힌 것 2  CD-DA 판정이 런타임에 아예 없다     -> 컷신 자막이 한 줄도 안 뜬다
남은 것    Lua 걷어내기 5 단계 (설계는 끝났고 재 보고 정할 일만 남았다)
```

**내일 첫 작업은 §3 의 측정 한 판이다.**  그것이 막힌 것 1·2 를 같이 답한다.

---

## 1. 지금 파일이 어떤 상태인가

**되돌리지 않은 상태로 묶었다.**  2026-08-24 초안이 들어가 있다.

```
cdda_subtitles.tsv    646 행 · 327 채움 (클립 200)
voice_subtitles.tsv   119 행 · 119 채움 (이벤트 56)
subtitle_pack.bin     57,894 B   버전 4 · 글리프 523 자 · ADPCM 49 · CD-DA 327
```

### 되돌리고 싶으면

초안 직전 백업이 같이 들어 있다 (`translation/*.bak_20260824`).

```bash
cp translation/cdda_subtitles.tsv.bak_20260824  translation/cdda_subtitles.tsv
cp translation/voice_subtitles.tsv.bak_20260824 translation/voice_subtitles.tsv
python tools/build_subtitle_pack.py && python tools/verify_subtitle_pack.py
```

되돌리면 팩이 8,808 B 로 돌아간다.  **팩 자체 백업은 없다** -- TSV 를 되돌리고
다시 굽는 것이 되돌리는 방법이다 (팩은 TSV 에서 완전히 재생성된다).

되돌려도 §2 의 열쇠 문제는 그대로 남는다.  그건 번역 데이터의 문제가 아니다.

### 안 들어 있는 것

```
패치 디스크 (build/patch/subtitle_resident/)   80 MB.  ROM 이 있어야 굽는다
원본 ROM · 폰트 원본 TTF
snatcher_ko_master.tsv (정적 텍스트 2.9 MB)     자막과 무관
```

디스크는 ROM 이 있는 컴퓨터에서 `python tools/build_subtitle_resident.py` 로
다시 구우면 된다.  **실기 확인은 그쪽에서만 된다.**  이 묶음으로 할 수 있는 것은
정적 작업(번역 · 빌더 · 엔진 코드 · 문서)이다.

---

## 2. 막힌 것 둘 — 자세히

### 2.1 ADPCM 열쇠가 이벤트를 구분하지 못한다  ★ 새로 드러난 것

`6_LIVE.md` §5 가 "번역이 늘면 충돌이 생길 수 있다" 고 예고했는데, **정도가
예상과 다르다.**  드물게 겹치는 것이 아니라 열쇠가 애초에 구분을 못 한다.

열쇠는 `(읽기주소 + 길이) & FFFF` 와 재생률이다.  그 합이 안 변하는 것은 맞다.
그런데 **그 합이 버퍼의 끝 주소**라, 같은 크기 등급의 음성이 전부 같은 값을 낸다.

```
5800 률 0E  <- 6 이벤트가 같은 열쇠
   0066+579A  <원문 9자>、<원문 9자>
   0069+5797  <원문 8자>、ミカ
   0069+5797  <원문 16자>
   0061+579F  なるほど <원문 9자>
   0058+57A8  そうか <원문 5자>
   0062+579E  <원문 17자>

FFFF 률 0E  <- 8 이벤트.  긴 음성이 전부 여기로 감긴다
```

값이 전부 `$0800` 의 배수인 것을 보라.  열쇠가 나르는 정보는 **"이 음성이 몇 KB
짜리인가" 뿐**이다.  대사 56 이벤트가 **25 열쇠**로 뭉갠다.

같은 순위(대사끼리)면 빌더가 먼저 온 것을 남긴다.  그래서 뒤에 온 31 개가
**소리 없이** 사라진다.  실기에서는 "자막이 안 뜬다" 로만 보인다.
빌더가 충돌 수를 세어 보고하고, 검증기가 왕복 대조에서 다시 잡는다.

```
python tools/build_subtitle_pack.py
  -> ★ ADPCM 지문 충돌 31 건 (서로 다른 이벤트끼리)
python tools/verify_subtitle_pack.py
  -> ★ 원본에 있는 ADPCM 자막 70 개가 팩에 없다
```

**후보: `sector` 열.**  `voice_events.tsv` 에 이미 있다.  음성 데이터가 실린
디스크 LBA 다.

```
초안 56 이벤트      sector 56/56 서로 다르다
ADPCM 전체 644 행   sector 537 개 서로 다르다
(sector, 끝주소)    543 개
```

끝 주소와 달리 음성마다 다르다.  **다만 아직 확인 안 된 것이 둘이다** -- §3.

> 재기 전에는 아무것도 고치지 말 것.  확실한 것은 "끝 주소로는 안 된다" 까지고,
> "sector 로 된다" 는 아직 후보다.  ("측정이 답할 수 없는 것으로 닫지 않는다")

### 2.2 CD-DA 판정이 런타임에 없다

`6_LIVE.md` §5 에 적혀 있던 것이고 그대로다.  **팩에는 색인이 굽혀 있는데
(지금 327 항목) Lua 가 CD-DA 를 아예 안 본다.  ADPCM 만 구현돼 있다.**

즉 **컷신 자막 194 클립은 번역이 다 들어갔는데 한 줄도 안 뜬다.**
번역이 모자라서가 아니라 읽는 쪽이 없어서다.

판정 자체는 ADPCM 보다 쉽다:

```
lba_from <= cdrom.audioPlayer.currentSector <= lba_to
```

색인이 `lba_from` 으로 정렬돼 있어 이분 탐색이면 되고, 613 항목이어도 비교
10 번이다.  겹침은 지금 0 이다 (검증기 확인).

---

## 3. ★ 내일 첫 작업 — 측정 한 판

**Lua 한 판으로 §2.1 과 §2.2 를 같이 답할 수 있다.**

`lua/PROBE_SUB_PACK_0_1_8.lua` 를 판을 올려(`0_1_9`) ADPCM 재생이 시작되는
프레임에서 `cdrom` 상태를 통째로 찍는다.  볼 것:

```
1  sector 가 재생 시작 시점에 보이는가
   ADPCM 은 CD 에서 먼저 읽어 두고 나중에 재생한다.  재생 시점에는
   currentSector 가 이미 지나가 있을 수 있다.  그러면 sector 는 못 쓴다
2  같은 음성을 다시 틀어도 같은 값인가
   끝 주소가 "합만 안 변한다" 였던 것처럼, 여기도 재 봐야 안다
3  (덤) CD-DA 재생 중 currentSector 가 어떻게 움직이는가
   -> 2.2 의 판정을 붙일 근거가 같이 나온다
```

**표본 잡는 법**: 위 `5800` 표의 6 이벤트가 접수처~국장실 한 장면에 다 나온다.
한 바퀴 돌면 "서로 다른 이벤트인데 열쇠가 같다" 는 표본이 그대로 모인다.

### 판 올릴 때 규칙 (이 프로젝트에서 지켜 온 것)

```
버전 번호와 덤프 경로를 **같이** 올린다.  덮어쓰지 않는다
   -> 로그를 만든 코드가 없으면 로그를 읽을 수 없다
"못 찾았다" 를 믿기 전에 프로브가 그것을 감지할 수 있었는지 먼저 확인한다
패치 실험은 **실제로 돌리는 디스크**로 한다 (원본에 구우면 당연히 안 나온다)
```

---

## 4. 그다음 — Lua 걷어내기 5 단계

`6_LIVE.md` §3 그대로 유효하다.  **순서가 중요하다** (한때 "AC 적재부터" 라고
적었다가 거꾸로였음이 드러났다 -- AC 는 런타임에 쓸 수 있다).

```
1  Lua 가 팩을 AC $1C0000 에 한 번 붓는다               몇 줄
2  엔진이 AC 에서 조회한다 (선형 탐색)
     -> Lua 의 레코드 만들기 · 글리프 1 KB 나르기가 통째로 사라진다
3  엔진이 VRAM 을 저장/복원한다 (버퍼는 AC $1F0400)
     -> Lua 의 제일 큰 나르기가 사라진다
4  상주부가 음성을 감지하고 엔진을 AC $1F0000 에서 복사한다
     -> Lua 가 $5B80 을 안 건드린다
5  AC 적재를 게임 부팅 경로로 옮긴다
     -> Lua 없음
```

각 단계 뒤에 Lua 에 남는 것:

```
2 번 뒤   엔진 올리기 + 매직 지우기 + VRAM
3 번 뒤   엔진 올리기
4 번 뒤   부팅 때 팩 붓기 한 번   <- 사실상 다 된 상태
5 번 뒤   없음
```

### 예산

```
헬퍼 여유 151 B    상주부 32  ->  남은 119 B      (4 번이 여기)
엔진 704 B         지금  362  ->  남은 342 B      (2·3 번이 여기)
AC 예약 256 KB     팩 57.9 KB  ->  넉넉
```

조회는 곱셈 없는 선형 탐색이고 VRAM 복사는 TIA/TAI 블록전송이라 342 B 안에
들어갈 것으로 **보이지만, 재 보고 정할 것.**

**2 번은 §2.1 과 얽힌다.** 엔진이 팩을 직접 조회하게 만들어도 열쇠가 같으면
같이 막힌다.  그래서 §3 의 측정이 2 번보다 먼저다.

### 5 번 손대기 전에

`_archive/build_records/DELETED_BUILDS_2026-08-13.md` 를 읽을 것.
CD 읽기가 느려 AC 로 옮긴 경위와 **철회된 비용 계산**이 들어 있다.
관련: `build/patch/0.4.5.6/manifest.json` 의 `ac_dynamic_packs`.
(이 두 파일은 묶음에 없다 -- 원본 폴더에 있다.)

---

## 5. 자리표 — 손대기 전에 볼 것

`tools/subtitle_layout.py`.  **자리는 한 곳에만 적는다.**
빌더마다 상수를 따로 들고 있었더니 실제로 겹친 적이 있다 (팩과 글리프
스테이징이 둘 다 `$1C0000`).

```
AC 예약  $1C0000-$1FFFFF  256 KB
  $1C0000  192 KB 까지   팩              지금 57.9 KB
  $1F0000    1 KB        엔진 이미지      상주부가 $5B80 으로 복사할 원본
  $1F0400    4 KB        VRAM 백업        음성 중 빌린 VRAM 을 떠 두는 자리
  $1F1400    2 KB        글리프 스테이징   ★ 임시 -- 엔진이 팩을 직접 읽으면 없어진다
  $1F1C00   57 KB        남는 자리

RAM   $7FA0 상주부 32 B · $5B80 엔진 704 B (음성 중에만)
VRAM  $7900 부터 19 x $40 워드 (음성 중에만 · 되돌린다)
```

`$1F0000` 과 `$1F0400` 은 **아직 아무도 안 쓴다** -- 3·4 단계에서 쓸 자리를
미리 잡아 둔 것이다.  `subtitle_layout.check()` 가 겹침과 예약 초과를 잡는다.

### 절대 규칙

```
Write 를 못 봤다 != 안전
안 돌더라도 코드가 있으면 산 자리다  (오버레이 구멍 다섯이 휴면 코드였다)
$1080-$1FFF 는 "음성 중 무변화" 로 잡히지만 쓰면 안 된다 --
   $1000-$10FF 가 SATB 이고 그 뒷절반이 안 쓰는 슬롯이라 안 바뀐 것뿐이다
VRAM $7900 은 되돌리니까 쓰는 것이다.  컷신마다 사정이 다르므로
   되돌리기를 빼면 안 된다
```

---

## 6. 번역 상태

### 들어간 것

```
CD-DA   대사 클립 223 중 194   (조각 319)   + 기존 c17 테스트 6
ADPCM   대사 이벤트 59 중 56   (조각 113)
```

초안은 `drafts/*.txt` 에 원문 그대로 있다.  다시 넣으려면:

```bash
python tools/draft_subtitles.py drafts/cdda_batch01.txt --cdda --check   # 검사만
python tools/draft_subtitles.py drafts/cdda_batch01.txt --cdda           # 반영
python tools/draft_subtitles.py drafts/voice_batch01.txt --voice
```

폭이 하나라도 넘치면 **아무것도 쓰지 않는다.**  실측 최대 184 px 였다
(한계 192 px) -- 19 자 어림보다 조금 더 들어간다.

### 왜 넣는 도구를 새로 만들었나

`tools/apply_translations.py` 의 검사를 여기 쓸 수 없다.  정적 텍스트는 **칸 수**
(18 칸)로 세지만 자막은 **픽셀 폭**(192 px)이다 -- Galmuri9 는 비례폭이라
`한`(11 px)과 `1`(5 px)이 같은 한 칸이 아니다.

그리고 자막은 시각을 갖는다.  한 클립을 몇 조각으로 나누느냐가 곧 화면이 몇 번
바뀌느냐다.  그래서 **조각 수는 초안이 정하고** 도구가 클립 길이를 그만큼 자른다.

### 검수해야 할 것  ★

`drafts/DRAFT_NOTES_2026-08-24.md` 에 전부 있다.  **원문이 whisper 전사뿐이라,
어디까지가 원문이고 어디부터가 추정인지 구분이 없으면 검수를 못 한다.**

```
§1  원문을 추정해 옮긴 곳       낱말이 틀린 전사를 문맥으로 복원한 목록
                                (人工秘符 -> 人工皮膚 · 合唱さん -> 勝算 등)
§2  추정이 안 서서 비운 21 클립  트랙 11·12 가 대부분.  다시 전사해야 채운다
§3  비명이라 뺀 8 클립           0.5~0.9 초.  연달아 뜨면 깜빡이기만 한다
§4  길이가 전사와 안 맞는 클립   c16_011 은 57.8 초에 전사가 한 줄뿐이다
§5  화자 판정 근거               국장에게 말하는 길리언만 새로 정했다
§6  고유명사 표
```

**트랙 11·12 는 다시 전사하는 편이 빠르다.**  한 어절만 남은 전사가 줄줄이다
(`あんたの` · `わしは` · `<원문 5자>`).

말투는 `translation/SPEAKER_STYLE.md` 를 따랐다.

---

## 7. 어제 고친 것 — 1 섹터 겹침

검증기가 CD-DA 구간 겹침 1 건을 잡았다.  같은 클립의 이웃 조각이 1 섹터
겹쳤는데, 원인이 부동소수였다.

```
609 / 75 = 8.12        인데      8.12 x 75 = 608.9999999999999
```

빌더가 `int(초 x 75)` 로 되돌리므로 한 눈금 아래로 떨어진다.
`draft_subtitles.py` 가 조각 경계를 **섹터 눈금 위**에 잡고 정수 계산으로
마이크로초 하나를 얹어 적는다.  얹는 양은 섹터의 1/13000 이라 시각에는 영향이
없고 되돌린 값이 정확히 맞는다.  겹침 0 이 됐다.

`math.ceil` 로는 안 된다 -- 딱 떨어지는 값은 올림이 안 되니까 그대로 남는다.

---

## 8. 묶음 안에 뭐가 있나

```
SUBTITLE_HANDOFF_2026-08-24.md      이 파일
SUB_docs/                           0_CUTSCENE_SUBS ~ 7_DRAFT   ★ 날짜순으로 읽을 것
handoff/                            SNATCHER_SUBTITLE_LIVE / _DRAFT
drafts/                             초안 6 개 + DRAFT_NOTES_2026-08-24.md
tools/                              자막 관련 빌더 · 검증기 · draft_subtitles.py
build_cutscene_subs/                팩 · 엔진 · 상주부 · 글꼴 · 세그먼트 표
translation/                        자막 TSV 4 개 + SPEAKER_STYLE.md + 백업 2 개
lua/                                PROBE_SUB_PACK_0_1_8.lua   ★ 여기서 판을 올린다
```

### 원본 폴더에 두고 온 것

```
build/patch/subtitle_resident/       패치 디스크 80 MB
build/patch/0.4.5.6/manifest.json    ac_dynamic_packs
_archive/build_records/DELETED_BUILDS_2026-08-13.md   5 번 손대기 전에 읽을 것
rom(japan)/                          원본 디스크
```

---

## 9. 다음에 할 것 (순서)

```
1  ADPCM 열쇠 재기          sector 가 재생 시점에 보이는가 · 다시 틀어도 같은가
                            -> Lua 한 판.  §2.1 과 §2.2 를 같이 답한다
2  CD-DA 판정 붙이기        색인은 이미 굽혀 있다.  읽는 쪽만 없다
                            -> 194 클립이 여기서 처음 화면에 뜬다
3  트랙 11·12 재전사        21 클립이 걸려 있다
4  Lua 걷어내기 2 번        엔진이 팩을 직접 조회 (1 번이 끝난 뒤에)
5  Studio 에 [위][중간][아래] 버튼    지금은 TSV 의 pos 열에 직접 적는다
```

---

## 10. 0.7 상주 컨트롤러의 151 B 재사용 주의  ★ 문제 발생 시 가장 먼저 볼 것

2026-08-24 네이티브 자막 0.7 POC는 `$7F49-$7FDF` **151 B 전체**를 상주
컨트롤러 자리로 쓴다. 이곳은 원본 게임에서 우연히 발견한 일반 공백이 아니다.
**우리 패치의 기존 helper가 계속 차지하던 영역**이며, BIOS 폰트 방식으로 바꾸면서
helper 코드가 줄어 비워진 꼬리다.

```
$7F49-$7FDF   151 B   기존 패치 helper의 비워진 꼬리
$7F49-$7FDF   151 B   PROBE_SUB_AC_RESIDENT 0.7.0-r1 상주 컨트롤러
                         현재 잔여 0 B
```

현재 POC가 이 자리를 쓰는 근거:

1. BIOS 방식 전환 뒤 helper 본체가 축소되어 이 151 B가 비었다.
2. 현행 `subtitle_resident` 이미지에서 `$7FA0`의 기존 32 B 상주부를 제외한 범위가
   `FF`인지 Lua가 실행 전에 검사한다.
3. 훅과 이 영역은 같은 오버레이에서 함께 나타나는 현행 구조를 전제로 한다.

그러나 앞으로 UI/폰트 helper를 키우거나, 뱅크·오버레이·적재 방식을 바꾸면 이
전제가 깨질 수 있다. 다음 증상이 생기면 다른 곳보다 **이 151 B 중복 사용부터**
확인한다.

```
부팅/장면 전환 정지
UI 복귀 실패 또는 글자 깨짐
특정 장면에서만 자막 엔진 소실
$601E 훅은 있는데 $7F49 코드가 달라짐
helper 빌드 크기 증가 또는 $7F49 이후가 FF가 아님
```

관련 파일:

```
tools/build_subtitle_resident_controller_poc.py
lua/PROBE_SUB_AC_RESIDENT_0_7_0.lua
build/cutscene_subs/resident_controller_0_7.json
```

### 0.7 최초 실패 기록

최초 판은 Lua가 프레임 시작에 AC 포트를 `$1F1C00`에 맞추고, 나중에 `$601E`
상주부가 읽는 구조였다. 그 사이 게임이 AC 포트를 바꿔 helper 대신 쓰레기
`0E 01 49...`를 `$5B80`에 복사했고 이를 호출해 첫 대사에서 정지했다.

`0.7.0-r1`은 helper AC 주소 설정을 상주부 내부로 옮겼고, 복사 뒤 `$5B80`이
`'S'`가 아니면 **절대 호출하지 않는 실행 방지 검사**를 151 B 안에 넣었다.
이 실패는 현재까지 151 B 영역 충돌의 증거가 아니라 AC 포트 소유권 문제다.

### 0.7.0-r1 런타임 통과  ★ 2026-08-24 확정

접수처 첫 음성에서 실제 통과했다. 다른 오버레이에서 Lua를 열어도 기다렸다가
오버레이 A가 나타나는 순간 `$7F49`에 151 B 컨트롤러를 설치했다.

```
resident                 151 / 151 B
Lua -> CPU 엔진 복사       0 B
VRAM -> AC 저장 불일치      0 / 2432 B
상주부 helper->renderer     PASS · magic 53 55 42 · state 2
자체 시간 전환              elapsed 3 / 123 · 두 조각 PASS
$5E20-$5E3F tail           0 / 32 B
AC -> VRAM 복원 불일치      0 / 2432 B
종료 상태                   helper status 2 · resident state 0
UI 복귀                     확인
```

따라서 현행 BIOS 패치 기준에서는 `$7F49-$7FDF` 151 B 재사용과 상주부 주도
엔진 교체가 모두 실기 런타임 경로에서 성립한다. 단, 위의 재사용 주의사항은
계속 유효하다. helper/뱅크 배치가 바뀌면 이 전제를 다시 검사해야 한다.
### 0.8.0 첫 native trigger 실패와 r1 수정

- 첫 0.8.0은 BIOS `AD_PLAY` 감지까지 성공했지만 자막만 뜨지 않았다.
  게임과 음성은 정상이라 투명 실패였다.
- 원인: BIOS에서 CPU `$7FDF`에 쓴 명령은 당시 MPR3에 매핑된 물리 뱅크에
  기록된다. 나중에 오버레이 A의 `$7F49` resident가 보는 `$7FDF`와 같은
  물리 RAM이라는 보장이 없었다. 실제 로그도 `state=0`이었다.
- r1은 게임 RAM을 새로 점유하지 않는다. Arcade Card 채널 1 데이터 포트
  `$1A10`을 AC `$1F03F0`의 1바이트 명령함에 고정했다. 자막 엔진은 채널 0
  `$1A00`만 사용하므로 포인터가 서로 섞이지 않는다.
- resident는 151 B에서 150 B로 줄었고 `$7FDF` 참조가 0개다. BIOS는 시작과
  종료 때 채널 1을 다시 명령함에 맞추므로 오버레이 전환과 무관하다.
- 정적 검증 SHA-256:
  - BIOS `5B23805A07825F8587176A9F4972CDA7B3C3CF67DA87C043DC37F1C28C441FDA`
  - resident `90CFEAC7A7AC16B4C0DD49F125DB2245BE2C07CC379E425D6D5390D98ED379A2`
- 아직 런타임 검증 전이다. 성공 로그는 `NATIVE START/TIMED/PASS` 확인 뒤 확정한다.

#### r1 런타임 결과와 r2 종료 청소 수정

- r1에서 AC 조회와 두 자막의 자체 시각 전환은 PASS했다.
- 그러나 음성 종료 뒤 VRAM `$7900-$7DBF`가 복원되지 않아 대화창 패턴이
  깨진 채 남았다. 소유자 표현대로 자막용으로 빌린 VRAM 패턴 캐시를 쓰고
  깨끗하게 닦지 못한 문제다. AC 팩/대사 조회 캐시 손상은 아니다.
- 원인: BIOS `AD_STAT`의 non-playing 경로가 state=3을 쓴 시점이 그 프레임의
  마지막 `$601E` 뒤일 수 있다. 다음 `$601E`가 없으면 restore helper가 실행되지 않는다.
- r2 BIOS는 종료 명령 직후 오버레이 A 훅/상주부 지문을 확인하고 resident를
  즉시 한 번 호출한다. resident가 사용하는 X/Y는 BIOS 호출 전후로 보존한다.
- r2 BIOS SHA-256:
  `DA588BD23440B1ECC1850CB2686DF666E7D55BD8D1004A4B76680AE96E3EA11B`
- Lua의 `$1A10` 관측도 잘못된 `pceMemory` 읽기 대신 AC `$1F03F0` 직접 읽기로
  고쳤다. 로그 첫 줄은 `LOAD_SUBTITLE_NATIVE 0.8.0-r2 loaded`여야 한다.

#### r2의 거짓 PASS와 r3 완전 복원

- r2 로그는 패턴 VRAM 2432 B 복원 0 diff를 냈지만, 접수처 첫 음성 뒤 UI에
  자막 스프라이트 모자이크가 그대로 남았다.
- 원인은 두 개였다.
  1. 패턴 `$7900-$7DBF`만 되돌리고 SATB `$1000`의 자막 스프라이트 항목을
     되돌리지 않았다. 남은 항목이 복원된 다른 얼굴/UI 패턴을 가리켰다.
  2. helper/renderer가 덮은 게임 캐시 `$5B80-$5E1E` 671 B도 되돌리지 않았다.
- r3는 시작 전에 패턴 VRAM 2432 B + SATB 512 B + CPU 게임 캐시 671 B를 모두
  AC에 저장하고 종료 직후 역순으로 복원한다.
  - 패턴 AC `$1F0400`
  - CPU 캐시 AC `$1F0E00`
  - SATB AC `$1F1100`
- helper는 425 B, AC 슬롯은 512 B로 확대했다. renderer `$1F1F00`과 겹치지 않는다.
  resident는 오히려 148/151 B다.
- r3 SHA-256:
  - BIOS `D28709AE94A9B18A108C0CCB30F72CC310B725331621AC78F26E7E2E83639D79`
  - helper `95EEDD861172E7B00C23BA6EC713C16BE2032A0D87805D82F4DF48B1EEFCAD1C`
  - resident `24C4EBA46D5C4AC702861D43759C51FAD10B541904DDACCED30279AE08224C67`
- r2의 `NATIVE PASS`는 VRAM 패턴만 검사한 불완전 판정이었다. r3부터는
  패턴 + SATB + CPU 캐시가 모두 0 diff여야 PASS다.

#### 0.8 r3/r4 중단 · 0.7.0-r1 기준점 복귀

- r3/r4에서도 접수처 첫 음성 뒤 UI 스프라이트 모자이크가 남았다.
- r4는 `AD_STAT 종료 경로 진입` 뒤 복원 완료 로그도 나오지 않았다.
- 더 이상 복원 대상을 추측해서 덧대지 않는다. 실제 UI 복귀가 확인됐던
  `0.7.0-r1`을 비교 기준점으로 복구했다.
- 복구된 공용 산출물:
  - helper 303 B / AC 슬롯 320 B / command 173 / status 174
  - resident 151/151 B / 로컬 state `$7FDF`
  - renderer 671 B
- `lua/PROBE_SUB_NATIVE_CLEANUP_0_1_0.lua`는 읽기 전용 측정판이다. 패턴 VRAM,
  SATB, CPU 캐시, 내부 Sprite/SAT 메모리(노출 시), AC 백업과 VDC `$13` 실행을
  AD_PLAY 전·종료 경로·종료 후 1/2/8/30/120프레임에 기록한다.
- 측정 순서: 0.7.0-r1 정상판 기준 로그 → 0.8 실패판 로그. 두 로그의 최초
  비복귀 자원만 다음 수정 대상으로 삼는다.

#### 0.7.0-r1 종료 기준 측정 결과

`probe_sub_native_cleanup_0_1_0_20260824_224921.tsv`로 정상판을 측정했다.

- AD_STAT 직전: 자막 패턴 637 B, SATB 124 B, `$5B80` 작업 RAM 661 B가 시작
  시점과 달랐고 자막 SATB 항목은 8개였다.
- 종료 후 1프레임: **패턴만 0 diff로 복구**됐다. SATB 124 B와 작업 RAM
  647 B 차이는 그대로였고 자막 항목도 아직 8개였다.
- 종료 후 2프레임: 게임이 SATB 512 B를 다시 썼고 자막 항목이 8개에서
  0개로 사라졌다. SATB는 시작 스냅샷과 61 B 달랐지만 UI 복귀는 정상이다.
- `$5B80`은 종료 뒤에도 시작 스냅샷과 647 B 다르다. 이 영역은 되감아야 할
  정적 캐시가 아니라 게임이 계속 갱신하는 작업 상태다.

따라서 0.7 정상 청소 순서는 `자막 주입 중지 -> 패턴 VRAM만 helper 복원 ->
게임의 다음 SATB 재생성`이다. 0.8 r3/r4처럼 옛 SATB와 `$5B80` 스냅샷을
강제로 덮는 방향은 폐기한다. 0.8 모자이크의 우선 원인은 복원 대상 누락이
아니라 종료 명령/renderer 중지와 게임 SATB 재생성의 호출 순서 파괴다.

cleanup probe의 `internal` 열은 Mesen의 `nesSecondarySpriteRam`을 자동 선택한
오탐이므로 PCE 판단에는 사용하지 않는다. 나머지 VRAM/SATB/RAM/VDC 값은 유효하다.

다음 읽기 전용 도구는 `lua/PROBE_SUB_NATIVE_ORDER_0_1_0.lua`다. E6800_0E의
종료 구간에서 BIOS AD_STAT, 프레임 하강, `$601E`, `$7F49`, `$5B80` 실행과
resident state/SATB 자막 항목 수를 순서 번호로 기록한다. 0.7 정상판에서 이
순서를 한 번 확정한 뒤에만 최소 native 종료 알림판을 만든다.

#### 0.7 종료 호출 순서 확정 · native 0.8.1

정상판 순서 측정 결과:

```
f5542 AD_STAT_PRE   state=2 · renderer · ours=8
f5543 FRAME_FALL_0  state=3 · renderer · ours=8
f5543 HOOK_601E
f5543 RESIDENT_7F49 state=3 -> helper 복원 실행
f5544 FRAME_POST_1  state=0 · helper · ours=8
f5544 게임 SATB 갱신 뒤 ours=0
```

BIOS 문맥의 `$7FDF`는 `EA`로 보였다. 이는 로컬 state의 물리 뱅크 불일치를
재확인한다. 정상판은 AD_STAT 안에서 복원하지 않는다. 다음 프레임 시작에 Lua가
state=3을 만든 뒤 같은 프레임의 정상 `$601E`가 resident를 호출한다.

이를 그대로 옮긴 `0.8.1`을 별도 산출물로 만들었다.

- BIOS: `build/bios_font/Syscard3_galmuri_sub_native_0_8_1.pce`
  - 99/280 B, AD_PLAY `$F61A->$FEC4`, AD_STAT `$F6EF->$FEE7`
  - AC `$1F03F0`에 start=1 / restore=3만 기록
  - AD_STAT 내부 resident 직접 호출 0회
  - CPU/SATB 스냅샷 및 강제 복원 없음
  - SHA-256 `E7E2381AABB6E53BD35FA90CCFF4036E961FA6D3C5C88E6664C9144028DCF294`
- resident: `resident_controller_native_0_8_1.bin`, 150/151 B
  - SHA-256 `90CFEAC7A7AC16B4C0DD49F125DB2245BE2C07CC379E425D6D5390D98ED379A2`
  - 과거 자막 표시 성공판 0.8 r1 resident와 byte exact 동일
- helper: 정상 0.7의 패턴 전용 303 B를 320 B 슬롯으로 패딩
- renderer: 정상 0.7과 같은 671 B
- 전용 로더: `lua/LOAD_SUBTITLE_NATIVE_0_8_1.lua`

0.8.1의 성공 조건은 helper 패턴 복원 직후 ours=8이어도 정상으로 보고, 다음
게임 SATB 재생성에서 ours=0이 되며 패턴/tail이 0 diff인지 확인하는 것이다.

실기에서 위 계측 PASS가 모두 났지만 UI 선택 스프라이트 깨짐은 남았다. 따라서
이 PASS는 아직 화면 복귀 성공 판정이 아니다. 앞선 효과음 오작동은 로그상 없다.
BIOS AD_PLAY 활성화는 E6800_0E 한 번만 기록됐다.

현재 우선 가설은 **시작 백업이 한 프레임 빠른 것**이다. 0.7은 playing 상승을
프레임 시작에서 확인한 뒤 state=1을 만들지만, 0.8.1은 AD_PLAY 내부에서 바로
명령 1을 쓴다. 같은 프레임의 `$601E`가 helper를 실행하면, 게임이 그 뒤 갱신할
패턴보다 낡은 스냅샷을 저장한다. 종료 diff=0이어도 낡은 그림으로 정확히 복원돼
UI가 깨질 수 있다. `PROBE_SUB_NATIVE_START_ORDER_0_1_0.lua`로 양쪽의 시작
AD_PLAY/$601E/resident/engine 순서를 비교한 뒤 시작 지연을 구현한다.

추가 관찰: 사용자는 대상 첫 대사를 재생하기 전 접수처 진입부터 UI 선택
스프라이트가 깨진다고 확인했다. 따라서 시작 백업 시점만으로 전체 현상을
설명할 수 없다. 0.8.1 BIOS를 재검토하니 AD_STAT 훅이 대상 여부를 검사하기
전에 매번 AC channel 1을 `$1F03F0`으로 재설정했다. 자막 활성화 로그가 없어도
효과음/음성 상태 확인 때 게임의 AC 채널 문맥을 파괴할 수 있는 버그다.

분리 검증 BIOS:

- `Syscard3_galmuri_sub_hook_noop.pce`: 동일 AD_PLAY/AD_STAT 훅과 원래 밀린
  명령만 실행. AC/자막/RAM 쓰기 0. 훅 자체의 부작용 여부를 검사한다.
- `Syscard3_galmuri_sub_native_0_8_2.pce`: AD_STAT에서도 먼저 E6800_0E를
  검사하며 비대상 경로의 AC 레지스터 쓰기는 0회다. 대상일 때만 mailbox를
  읽고 restore=3을 쓴다.
- NOOP SHA-256 `20FD360412FA352EC4992FF86B5C111AD2D7B36D7B9F59BE2243185CFE9A28A9`
- 0.8.2 SHA-256 `49B0304897ED5C6BDF2DA64ACE961A2380FA446EE4E1F7C7631FF95B8CD29D64`

검증 순서: NOOP BIOS + Lua 없음으로 접수처 진입 → 깨끗하면 0.8.2 BIOS와 기존
0.8.1 loader 조합으로 대상 전/후를 나눠 본다. 대상 전부터 깨지면 훅/cave
자체를, 대상 뒤에만 깨지면 mailbox 채널 보존 또는 시작 시각을 다음 대상으로 삼는다.

실기 분리 결과: NOOP BIOS와 0.8.2 gated BIOS 모두 Lua 없이 접수처까지 화면이
깨끗했다. 따라서 BIOS 훅/cave 자체는 안전하며, 대상 전 깨짐의 원인은 0.8.1
AD_STAT의 무조건 AC channel 1 재설정으로 확정한다. `LOAD_SUBTITLE_NATIVE_0_8_2.lua`
는 gated 코드 지문까지 검사한 뒤 기존 검증 core를 실행하여 구 BIOS 혼용을 막는다.

그러나 0.8.2에서 loader를 켜자 대상 음성 전부터 즉시 UI가 깨졌다. 원인은
resident idle 경로가 매 `$601E`마다 `$1A10`을 mailbox로 읽은 것이다. 비대상
상태에서는 BIOS가 channel 1을 mailbox에 맞추지 않으므로, resident가 게임 AC
데이터를 state 명령으로 오인해 helper/renderer를 실행했다. 즉 AC 데이터 주소가
고정이어도 **AC 포트의 현재 포인터는 고정이 아니며**, 이를 공유 신호로 쓸 수 없다.

AC mailbox 설계를 폐기한 `0.8.3 native poll`을 만들었다.

- BIOS `Syscard3_galmuri_sub_native_poll_0_8_3.pce`
  - AD_PLAY/AD_STAT 훅 0, 원본 명령 유지
  - `$FEC4`에 62 B 읽기 전용 판정 함수만 배치
  - AC 포트 접근 0; local state `$7FDF`, 키 `$22A6/$22A7/$22AA`, 재생 제어
    `$180D & $20`만 읽는다.
- resident `resident_controller_native_poll_0_8_3.bin` 151/151 B
  - 기존 첫 `LDA state` 3 B를 `JSR $FEC4` 3 B로 교체하여 크기 증가 없음
  - BIOS 함수는 resident와 같은 오버레이 문맥에서 호출되므로 `$7FDF` 물리 뱅크가 같다.
- loader `LOAD_SUBTITLE_NATIVE_POLL_0_8_3.lua`
  - 초기 데이터/코드 설치만 수행하고 음성 명령 쓰기는 0 B다.

#### 다음 분리 단계: resident 디스크 정적 설치

`tools/build_subtitle_native_poll_disc_0_8_3.py`가 실기 통과 resident 151 B를
오버레이 A의 전체 helper 꼬리 `$7F49-$7FDF`에 굽고 `$601E`를 `JSR $7F49`로
연결한 별도 디스크를 생성했다.

- 폴더: `build/patch/subtitle_native_poll_0_8_3/`
- resident SHA-256: 실기 통과본과 동일
  `B203210BC4AFD1DA35D614E4FA3C49B644DC814A070F132D9396CFB9182E4B21`
- Track 02 SHA-256:
  `9DC0D0C6A4840045D366D106CACCB7790A3DC13B5419BE1FBC3082805750FCA4`
- 오버레이 지문 6곳 일치, EDC/ECC 섹터 251/254 재계산
- 24개 트랙 완비. Windows symlink 권한이 없으면 원본 0.4.5.6 트랙에 대한
  하드링크를 만든다(추가 데이터 복사 없음).

기존 `LOAD_SUBTITLE_NATIVE_POLL_0_8_3.lua`는 resident가 이미 디스크에서
나왔으면 `디스크 ... 확인 · Lua CPU 코드 설치 0 B`를 출력한다. 이 단계에서는
팩/helper/renderer AC 적재만 Lua에 남는다. 실기 통과 뒤 Track 24 별도 blob과
기존 `load_blob` 경로로 그 세 덩어리를 옮긴다.

실기 결과: 디스크 resident 감지, 자동 시작, helper 복원, 게임 SATB `ours=0`,
실제 자막 표시와 UI 복귀까지 전부 확인했다. 따라서 CPU resident 정적 설치는 PASS다.

#### 0.8.4 완전 native AC preload 시험판

검증된 오버레이 A의 기존 `load_blob`을 재사용한다.

```
load_blob runtime     $7E64
변수                   $7FE0-$7FE7 (resident $7FDF 바로 다음)
Track24 append 시작    상대 $C639 · 절대 LBA 285894
pack                   31 sectors -> AC $1C0000
helper                  1 sector  -> AC $1F1C00
renderer                1 sector  -> AC $1F1F00
합계                   33 sectors · raw 77,616 B
```

- BIOS `Syscard3_galmuri_sub_native_poll_0_8_4.pce`: 153/280 B, ADPCM 훅 0.
  state `$FF`이면 `$7FE0-$7FE7`을 채워 기존 `$7E64 load_blob`을 세 번 호출한 뒤
  state 0으로 전환한다. 실패는 `$FE`로 고정해 매 프레임 CD 재시도를 막는다.
- resident `resident_controller_native_poll_0_8_4.bin`: 151 B, 초기 state `$FF`.
- 디스크 `build/patch/subtitle_native_poll_0_8_4/`: Track02 resident + Track24 payload,
  나머지 22개 트랙 하드링크.
- 검증기 `VERIFY_SUBTITLE_NATIVE_POLL_0_8_4.lua`: 읽기 전용. AC/CPU/음성 명령
  쓰기 0 B로 세 payload 전체 byte exact와 자막 시작/복원/SATB 복귀만 확인한다.

정적 해시:

- BIOS `AAEA50109601BD50DD601FD4698392BF0BF83F766B72305AB15F1C2BCF7EB457`
- resident `871692236BC3392D0B58DD051498380376F855F073C6B41E4136BCCFBBB4616A`
- Track02 `ADCE4685598C0553FADBDAC1BA80FF3FF28B9DAD612B855FC1C29927BEAC5961`
- Track24 `F0BAE5C506B7D7D519193BD9EA234772701F48142DFCE0F0B612DBBB9DA6437C`

실기 첫 실행에서 state `$FE`, `TRACK24 PRELOAD FAIL`이 났다. 원인은 디스크
헬퍼의 물리 바이트가 `$7E64`에도 보인다는 이유로 그 별칭을 직접 호출한 것이다.
`load_blob`은 원래 `$BE64`에서 조립됐고 내부 JSR/변수 피연산자도 `$BFxx` 절대
주소다. 따라서 `$7E64`에서 실행하면 코드 바이트는 같아도 내부 주소가 다른 창을
가리킨다.

`0.8.4-r1`은 기존 정식 트램펄린과 같은 호출 계약으로 고쳤다.

```
PHP / SEI
MPR5 보존 -> Bank $69를 MPR5($A000-$BFFF)에 매핑
$BFE0-$BFE7 변수 설정 -> JSR $BE64
MPR5 / P / X / Y 복원
```

- BIOS: `build/bios_font/Syscard3_galmuri_sub_native_poll_0_8_4_r1.pce`
- SHA-256: `C43EF3BB5477B4143905525A641B0D65B10255F6500B9E1D63055C6A7EC29269`
- BIOS cave 177/280 B, ADPCM 훅 0.
- 실패 state를 pack `$F1`, helper `$F2`, renderer `$F3`으로 분리했다.
- 기존 `subtitle_native_poll_0_8_4` 디스크는 그대로 쓴다. Track24 끝 77,616 B가
  현재 append payload와 byte-exact임을 확인했다.
- 검증기는 같은 `lua/VERIFY_SUBTITLE_NATIVE_POLL_0_8_4.lua`이며 `$F1-$F3`도
  어느 적재에서 실패했는지 출력하도록 갱신했다.

`r1` 실기에서는 load_blob가 성공을 반환했지만 pack/helper/renderer가 전부
무관한 데이터였고 `SNSB`도 AC 2 MiB 전체에 없었다. 목적지가 아니라 CD 섹터
주소 문제였다. Track24 CUE는 `INDEX 01 00:03:00`, 즉 파일 시작에서 225섹터인데
빌더의 `TRACK24_FILE_LBA=234999`는 150섹터 pregap을 가정했다. 그래서 append를
75섹터 늦게 읽었다.

`0.8.4-r2`에서 파일 시작 LBA를 `234924 = 235149 - 225`로 고쳤다.

```
pack       상대 $C5EE (50670) -> AC $1C0000
helper     상대 $C60D (50701) -> AC $1F1C00
renderer   상대 $C60E (50702) -> AC $1F1F00
```

- BIOS: `build/bios_font/Syscard3_galmuri_sub_native_poll_0_8_4_r2.pce`
- SHA-256: `1B723A4BF7B0F80E792A3A0B061AB11BBEEA6DB5CC8FCC342512B4F4C7409A7B`
- 기존 0.8.4 디스크와 검증 Lua는 그대로 사용한다.

실기 결과 `0.8.4-r2` Track24 native preload PASS (2026-08-24):

```
pack       불일치 0/61605 B
helper     불일치 0/320 B
renderer   불일치 0/671 B
```

검증 Lua의 AC/CPU/음성 명령 쓰기는 전부 0 B였다. 따라서 Track24 섹터 조회,
기존 `$BE64 load_blob`, MPR5 Bank69 매핑, 세 AC 목적지까지 byte-exact로 확정한다.
다음 확인은 E6800_0E 첫 음성의 자동 자막 표시와 종료 후 게임 SATB/UI 복귀다.

첫 음성 실기에서 자동 감지/renderer 설치/복원/UI 복귀는 모두 통과했지만 자막은
표시되지 않았다. 읽기 전용 `PROBE_SUB_NATIVE_RENDER_0_1_0.lua` 측정 결과:

```
AC selector   00 00 00 00 00 00
CPU selector  00 00 00 00 00 00
elapsed=0 · ready=0 · count=0 · ours=0 (재생 끝까지 동일)
```

원인은 0.8.3 loader가 AC renderer `+366`에 쓰던 E6800_0E 선택 키
`78 30 00 00 68 0E` 6 B를 완전 native Track24 payload에 넣지 않은 것이다.
엔진이나 SATB의 실행 실패가 아니라 조회 입력 누락으로 확정한다.

`0.8.4-r3`은 원본 0.8.3 renderer를 보존하고 선택 키가 내장된 별도 renderer를
Track24에 실었다.

- renderer: `build/cutscene_subs/resident_renderer_slot_native_poll_0_8_4_r3.bin`
- 디스크: `build/patch/subtitle_native_poll_0_8_4_r3/`
- CUE: `Snatcher CD-ROMantic (Japan) [KO subtitle native 0.8.4-r3].cue`
- Track24 SHA-256: `15724498EFDC4767C93C5364D04A9E5D5A6CB3C5355240F536E6A81BEA177D5E`
- BIOS는 r2와 byte-identical: `1B723A4BF7B0F80E792A3A0B061AB11BBEEA6DB5CC8FCC342512B4F4C7409A7B`
- append 33섹터를 다시 추출해 renderer sector 및 selector 6 B byte-exact 확인.

#### 0.8.4-r3 완전 native 실기 통과 ★ 현행 기준점

접수처 E6800_0E 첫 음성에서 실제 자막 표시와 UI 복귀까지 전부 확인했다.

```
Track24 -> AC pack       0/61605 B
Track24 -> AC helper     0/320 B
Track24 -> AC renderer   0/671 B
AC selector              78 30 00 00 68 0E PASS
조각 1                   elapsed=4,   ready=1, count=16, SATB ours=16
조각 2                   elapsed=121, ready=1, count=8,  SATB ours=8
종료 helper              status=2
게임 SATB 재생성         ours=0
실제 화면                2조각 자막 표시 · UI 복귀 확인
```

검증 Lua 두 개 모두 AC/CPU/VRAM/음성 명령 쓰기 0 B였다. 즉 다음 전 경로가
Lua 적재나 제어 없이 디스크+BIOS+상주 코드만으로 동작한다.

```
Track24 payload -> AC 선적재
기존 $BE64 load_blob
디스크 resident의 대상 음성 poll
helper VRAM 저장 -> renderer 교체
AC 색인 조회 -> 자체 elapsed 조각 전환
SATB 자막 삽입
음성 종료 -> VRAM helper 복원
게임 SATB 재생성 -> UI 복귀
```

현행 native 기준점은 `0.8.4-r3`이다. 0.8.4/r1/r2는 각각 실행창, pregap,
selector 누락을 찾기 위한 중간판이며 이후 작업의 기반으로 사용하지 않는다.

#### 0.8.3 native poll 실기 통과 ★ 새 기준점

접수처 첫 음성에서 다음 전 경로를 실제 화면으로 확인했다.

```
Lua 로드 직후 / 대상 전 UI     깨끗함
E6800_0E 자동 감지             PASS
helper 저장 -> renderer 교체    PASS
2조각 자체 시각 자막 표시       PASS
음성 종료 자동 감지             PASS
패턴 VRAM helper 복원           PASS
게임 SATB 재생성                PASS
UI 선택 스프라이트 복귀          확인
```

따라서 현행 native 기준점은 `0.8.3 native poll`이다. 핵심 계약:

- BIOS AD_PLAY/AD_STAT 훅을 쓰지 않는다.
- AC channel 포인터를 명령 전달용으로 쓰지 않는다.
- resident의 `$601E` 문맥에서 BIOS `$FEC4` 판정 함수를 호출한다.
- BIOS 함수는 AC와 X/Y를 건드리지 않고 local state/음성 키/재생 비트만 읽는다.
- 0.8.0~0.8.2의 AC mailbox, 즉시 resident 호출, SATB/CPU 강제 복원 코드는
  재사용하지 않는다.

확정 파일과 SHA-256:

- `build/bios_font/Syscard3_galmuri_sub_native_poll_0_8_3.pce`
  `2F588E192F7FB6EF54305979A8B4A170ECC7F044510A374ED1239B6D2AEE52AD`
- `build/cutscene_subs/resident_controller_native_poll_0_8_3.bin`
  `B203210BC4AFD1DA35D614E4FA3C49B644DC814A070F132D9396CFB9182E4B21`
- `lua/LOAD_SUBTITLE_NATIVE_POLL_0_8_3.lua`

## 2026-08-25 번역·미수집·음성 재수집용 통합판

현행 마스터를 0.4.5.9-collection으로 다시 빌드하고, 0.8.4-r3 native poll
자막 경로를 같은 디스크에 통합했다. 기존 0.4.5.8과 기존 음성 덤프는 수정하지
않았다.

- CUE: `build/patch/0.4.5.9-subtitle-collection/Snatcher CD-ROMantic (Japan) [KO 0.4.5.9 subtitle collection].cue`
- BIOS: `build/bios_font/Syscard3_galmuri_0_4_5_9_subtitle_collection.pce`
- BIOS SHA-256: `32B018C5EC9A2DF6DB887D1C4D6E85442F68BE5663FE5BF47E7100256BA08621`
- Track24 append: 77,616 raw B, 디스크 꼬리와 byte-exact 확인
- Track24 preload 목적지: pack `$1C0000`, helper `$1F1C00`, renderer `$1F1F00`
- 현 단계 자막 selector는 접수처 첫 음성 E6800_0E 고정 POC다. 범용 키 수집·매칭을
  위한 플레이 판이며 모든 음성의 자막이 뜨는 최종판은 아니다.

자막 시험 Lua는 수집 전에 단독으로 확인한다. 실제 처음부터 완주 수집에서는
미수집 대사 Lua와 음성 Lua를 각각 별도 Script Window에 함께 로드해도 된다.
둘은 출력 파일과 콜백 역할이 겹치지 않는다.

1. `lua/TEST_SUBTITLE_COLLECTION_0_1_0.lua`
   Track24 선적재, 첫 음성 자막, 종료 복원과 SATB/UI 복귀를 읽기 전용으로 검증.
2. `lua/COLLECT_MISSING_TEXT_0_1_0.lua`
   실시간 preloader에서 한국어 포인터 치환이 실제 실패한 완성 레코드만 기록.
   출력은 `snatcher_tool/logs/runtime_missing_text_raw_v010.tsv`. 레코드 경계,
   꼬리행, 앞 공백과 원시 바이트를 보존하며 음성/UI/VDC 수집은 끈다.
3. `snatcher_tool/mesen/COLLECT_VOICE_KEYS_AUDIO_0_1_1.lua`
   텍스트를 건드리지 않고 ADPCM 6 B 키와 완전 RAM 클립, CD-DA sector 구간만 기록.
   6 B는 `sector u24 + (readAddress+audioLength) 끝주소 u16 + rate u8`이다.
   0.1.0은 가운데 2 B를 writeAddress로 잘못 기록했으므로 사용하지 않는다.
   출력은 `snatcher_tool/logs/voice_key_events_raw_v011.tsv`, 새 클립은
   `snatcher_tool/logs/voice_clips_v011_fresh/`에 둔다.

기존 음성 자료와 새 완주 수집 계약:

- `voice_clips/`의 248개, 6.74 MiB가 기준 원본이다.
- 옛 248개와 옛 `voice_events_raw.tsv`는 참고용으로 그대로 보관만 한다.
- 새 완주 수집은 `voice_clips_v010_fresh/`와
  `voice_key_events_raw_v010.tsv`에서 0부터 시작한다.
- 새 수집 안에서 같은 내용이 반복될 때만 기존 FNV 변형과 `vXXXXXXXX.bin`으로
  중복 저장을 막는다. 옛 부분 수집의 파일명·횟수·이벤트는 승계하지 않는다.
- 2026-08-20 보관본은 243개이며 현행 폴더에만 5개가 더 있다. 따라서 보관본으로
  현행 폴더를 되돌리면 안 된다.

## 2026-08-25 오탐 확인 — E6800_0E 고정 selector가 실은 2바이트짜리였다

미수집 대사 수집 플레이 중 사용자가 Sprite Viewer로 **폐공장 장면에서 "길리언
시드다."(접수처 전용 자막)가 잘못 뜨는 것**을 직접 발견했다 (Sprite RAM 조사
중 우연히 포착 — 재현 조건 특정 안 됨, 다음에도 뜨면 이 섹션부터 볼 것).

`tools/build_subtitle_native_poll_bios_0_8_3.py`의 `$FEC4` 판정 함수를 열어
확인한 결과, "E6800_0E selector"라는 이름과 달리 **런타임 비교는 `$22A7==0x68`
· `$22AA==0x0E` 딱 2바이트뿐**이다 (`$22A6==0`은 추가 조건이지만 특정 값이
아니라 "0인가"만 본다). §2.1 이 이미 경고한 "끝주소+재생률만으로는 음성
크기 등급만 구분한다"는 바로 그 결함을, 완전 native POC의 런타임 판정
코드가 그대로 물려받았다 -- 섹터는 애초에 안 읽는다.

`voice_events.tsv`에서 같은 키(`write_address=6800`, `playback_rate=0E`)를
찾으면 **서로 다른 23개 이벤트가 겹친다**:

```
0007  sector 003078  길리언    <원문 27자>  (자막 원문, 정상)
0060  sector 0033FC  메탈기어  <원문 6자>。<원문 20자>
0063  sector 003443  길리언    <원문 8자>、<원문 12자>
0077  sector 003489  메탈기어  <원문 6자>…<원문 16자>
… 총 23건 (나머지는 speaker/jp_whisper 미기록 -- kind=기타)
```

0060/0063/0077의 섹터대(0033FC~003489)가 §5 CD-DA 번역에서 이미 확인한
"M지구 공장 터로 직행" 장면과 겹친다 -- 폐공장에서 이 중 하나가 재생되며
우연히 같은 (끝주소, rate)라 오탐이 난 것으로 보인다 (섹터 로그만으로는
어느 이벤트인지 확정 불가 -- 실기 재현 시 어떤 음성이 재생 중이었는지
같이 남길 것).

**수집 데이터 오염 아님.** 미수집 대사 Lua(`COLLECT_MISSING_TEXT`)와 음성
키 Lua(`COLLECT_VOICE_KEYS_AUDIO`)는 이 자막 오버레이와 완전히 무관한
별도 콜백이라, 오탐 자막이 화면에 잘못 떠도 오늘 모으는 TSV에는 영향이
없다. §2.1의 섹터 기반 키 작업(§3 측정 한 판)이 이 오탐의 근본 해결책이며,
그 작업이 곧 이 문제도 같이 푼다 -- 별도 수정 불필요, 우선순위만 확인.

### 같은 스크린샷에서 드러난 별개 문제 — 자막이 초상화를 가린다  ★ 미해결

오탐과는 별개로, 같은 화면에서 사용자가 **자막 스프라이트가 초상화 자리를
가리는 것**을 직접 확인했다. `SNATCHER_SUBTITLE_PLACED_2026-08-23.md` §1/§4에
이미 원인이 적혀 있다 -- 새로 생긴 버그가 아니라 **그때 고친 것의 반대급부가
아직 안 풀린 것**이다.

```
2026-08-23 오전 이전   자막이 게임 그림보다 뒤에 그려짐 -> 초상화가 자막을 가림
2026-08-23 오전 수정   훅을 $606F -> $601E 로 옮겨 자막을 게임 그림·초상화보다
                       항상 앞에 그리도록 고침 (그 문서 §1)
자리 (§4)              그림은 x 36..228 (192px, 건드릴 수 없음). 그 아래
                       검은 띠는 원래 메뉴·초상화가 앉는 자리인데, 자막도
                       바로 그 자리(y=122, 가운데 x=128)에 얹는다
```

즉 **자막과 초상화가 애초에 같은 화면 영역을 공유**하고, "앞에 그리기"
수정으로 승자만 뒤바뀌었다 -- 이제 초상화가 자막을 못 가리는 대신
**자막이 초상화를 가린다.** 지금까지 테스트가 대부분 이 겹침이 안 나는
장면 위주였거나, 겹치는 순간을 놓쳤을 가능성이 있다. 오늘 건은 오탐(위
섹션)이 우연히 이 자리 충돌까지 같이 드러낸 것뿐 -- 오탐이 아니어도 자막이
정상적으로 뜨는 장면에 초상화가 같이 있으면 똑같이 가려질 것이다.

해결 방향은 검토 안 됨 (다음 후보들, 우선순위 미정):

```
1  자막을 초상화보다는 뒤 · 게임 그림보다는 앞으로 (3단 우선순위 필요 -- 지금은 2단)
2  초상화가 있는 장면에서는 자막 Y 를 위로 옮기거나 폭을 줄임 (§9 의 [위][중간][아래]
   pos 열 작업과 겹친다 -- 아직 TSV 에 pos 열 자체가 없음, 미구현)
3  초상화 SATB 슬롯을 감지해서 자막 슬롯을 그 뒤로 배치 (슬롯 번호로 z-order 결정되므로
   원리상 가능 -- $601E 훅 코드가 슬롯 0 부터 차지하는 지금 방식과 충돌 검토 필요)
```
