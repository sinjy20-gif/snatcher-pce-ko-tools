# Mednafen 계측 안내 + 환경 함정 — 2026-09-07

## ✅ 결과 — rc12 합격 (밤 늦게 확인)

```
빌드        build/patch/0.6.0-rc12-cdda-ac-latch-init
방식        완료 표식을 게임 RAM 이 아니라 CD-DA 전용 AC $1F1EE7 ($A5) 에 둔다
            전원 직후의 비정상 private state 와 실제 새 CD 요청에서 표식을 지운다

판정 환경   RetroArch / Beetle PCE SuperGrafx   ← 실제 출하 환경
  ① 트랙 17 오프닝 자막      정상
  ② 트랙 20                  정상 (두 번 재생 안 함)
  ③ 트랙 20 뒤 ADPCM 음성    정상   ★0.6.1 이 죽었던 자리
```

**rc4~rc11 은 전부 실패다.** 그 여덟 판이 모두 "두 번째 무장을 막는다" 한 가족이었고,
못 막거나(rc4) 정당한 무장까지 막거나(rc5~rc8) ADPCM 을 죽였다(0.6.1).
성공한 rc12 만 **표식을 CPU RAM 밖(AC)으로 뺐다** — 그게 갈림길이었다.

⚠ 남은 것: 자막이 음악보다 먼저 끝나는 트랙이 **14 개**인데 확인한 것은 트랙 20 뿐이다
(§4 표). 나머지 13 개는 미확인.

> **분석·빌드 이력은 이 문서가 아니라 [`SNATCHER_2026-09-07_NIGHT_HANDOFF.md`](SNATCHER_2026-09-07_NIGHT_HANDOFF.md) 를 볼 것.**
> 그쪽이 더 나중이고 더 완전하다.  CD-DA 재무장의 기전, rc4~rc12 이력,
> 코드 지도가 전부 거기 있다.
>
> 이 문서는 **거기 없는 것만** 남긴다 — 레트로아크 환경에서 어떻게 재고,
> 반나절을 날린 함정 둘이 무엇인지.

---

## 1. 레트로아크에서 프로브를 못 돌릴 때 — Mednafen 단독판

레트로아크에는 Lua 가 없다.  그런데 **Beetle 은 Mednafen 의 libretro 이식**이다.
단독판을 쓰면 같은 증상이 나면서 **디버거가 붙는다.**

```
D:\Download\mednafen-1.32.1-win64\mednafen.exe
  -force_module pce            ★없으면 디버거 없는 pce_fast 로 잡힌다
  -ffspeed 8 -fftoggle 1       빨리감기 8배 토글 (백틱 ` 키)
  -pce.cdbios <우리 BIOS>  "<CUE>"
```

빨리감기는 **측정을 안 망친다.**  에뮬 안의 시간은 그대로고 실제 시계로 프레임을
더 많이 돌릴 뿐이다.

```
ALT+D 디버거 · ALT+1 CPU · ALT+3 메모리 · SHIFT+W 쓰기 중단점
W A S D 방향 · 키패드 3/2 = I/II · Enter=RUN · Tab=SELECT
F1 키 목록 · F5/F7 상태 저장·불러오기
```

**F5 를 장면 직전에 찍어 두면 같은 자리를 몇 번이든 다시 잡을 수 있다.**

### 쓰기 중단점 하나로 CD-DA 수명을 다 본다

`SHIFT+W` → `5E1A` (범위 말고 한 바이트).  트랙 하나에 세 번 멈춘다.
그 세 자리는 BIOS 전체에서 `$5E1A` 에 쓰는 곳 전부다 (직접·인덱스 전수 스캔):

```
$F9DC   LDA #$02 -> STA $5E1A     cdda_start     무장
$FF24   LDA #$01 -> STA $5E1A     cache_arm      게임 요청을 받았다
$FF59   STA $5E1F -> STZ $5E1A    cache_restore  철거
```

**주소를 옮겨 적을 필요 없다 — 빨간 줄 바로 위 한 줄만 보면 된다.**
`LDA #$02` 면 무장, `LDA #$01` 이면 요청, `STZ` 면 철거다.

### 시각은 TS 로 읽는다

레지스터 패널의 `TS` 가 마스터클럭(21.48 MHz) 누적값이다.  두 정지의 TS 를 빼서
21,477,270 으로 나누면 초가 나온다.  이걸로 "철거 0.014초 뒤 재무장" 을 잡았다.

### ⚠ .cmd 는 순수 ASCII 로만

cmd.exe 는 `.cmd` 를 시스템 코드페이지(CP949)로 읽는다.  UTF-8 한글 주석을
넣으면 글자가 깨지는 데서 그치지 않고 **줄 구조가 무너져 조각이 명령으로
실행된다.**  실제로 당했다.

만들어 둔 실행 파일: `build/patch/0.6.0-rc6-latch-fix/RUN_MEDNAFEN_RC6.cmd`
(그 빌드는 폐기됐지만 BIOS 경로만 바꾸면 그대로 쓸 수 있다)

---

## 2. 함정 ① — RetroArch 는 게임 폴더의 BIOS 를 안 쓴다

`system_directory` 의 **`Syscard3.pce`** 라는 이름만 읽는다.  우리 BIOS 는
`Syscard3_galmuri_<버전>.pce` 라 그냥 두면 **예전 빌드가 조용히 돈다.**

```
그날 cfg   system_directory = C:\snatcher\build\patch\0.6.0-rc2
           Syscard3.pce  1C1EB571…  = RC2   (09-07 16:45 파일)
           RC4 는 67D3AAF1… 이고 18:15 에 만들어졌다
```

→ "RC3 도 안 고쳐졌다" 로 올라온 관측이 **실은 전부 RC2 였다.**
빌드 하나를 통째로 날린 셈이다.

**규칙 둘:**

1. 빌드마다 `Syscard3.pce` 사본을 같이 만든다 (rc3-restored 는 이미 그렇게 돼 있다).
2. 테스트 전에 `retroarch.cfg` 의 `system_directory` 와 그 폴더의
   `Syscard3.pce` 해시를 확인한다.  "바꿨다" 는 기억을 믿지 말 것.

```bash
grep '^system_directory' /c/RetroArch-Win64/retroarch.cfg
```

---

## 3. 함정 ② — ROM 상주 빌드에서 스케줄러 패처를 돌리면 안 된다

빌더가 마지막에 찍는 `[3/3] 다음 단계` 안내가 **낡았다.**

```
python tools/build_snatcher_0_4_7_2_cdda_scheduled.py --rom-resident --version <V> --tag <TAG> --adpcm-reuse
python tools/patch_track24_subtitle_pack.py <V> --write
python tools/patch_bios_cpu_cache.py <V> --write
python tools/patch_bios_cdda_rom_resident.py <V> --write     ★스케줄러도 이것이 심는다
```

`patch_bios_cdda_scheduler.py` 는 **돌리지 말 것.**  두 도구가 심는 스케줄러가
다르다 — `build_snatcher_cdda_scheduler` 안에서 `private_state_cpu` 유무로
종료에 STATE=**0** 을 쓸지 **3** 을 쓸지가 갈린다.  둘 다 돌리면 상주부가
`CD-DA scheduler 자리 $ECF9가 비어 있지 않다` 로 멈추고, `--existing` 으로
우회하면 **엉뚱한 변종이 실린 채 넘어간다.**

최상위 빌더도 `all_in_one` 이 아니라 그것을 감싸는 `0_4_7_2_cdda_scheduled` 다.
`all_in_one` 을 직접 부르면 **안 쓰는** 레거시 2줄 엔진의 제약에 걸려
`Track 17 앞 두 줄이 이어지지 않는다` 로 멈춘다 (그 우회가 바깥 빌더에 있다).

---

## 4. 트랙 길이는 계산해서 쓸 수 있다

```
초 = bin 파일 크기 ÷ 2352 ÷ 75
```

이걸로 "자막이 음악보다 얼마나 먼저 끝나는가" 를 전 트랙에 대해 냈다.

```
트랙  1   여유 -0.1초        트랙  4   여유 0.0초        트랙 16   여유 0.6초
나머지 14개  여유 4.2 ~ 17.3초
```

여유가 0 에 가까운 세 트랙만 증상이 안 보였다.  **자막이 음악과 같이 끝나면
재무장할 시간이 없다** — 밤 인계서의 "남은 트랙 시간이 얼마냐로 갈리는 경주"
와 같은 이야기다.

---

## 5. 프로브

`lua/CDDA/0.1.0-rearm-gate.lua` — 메센용, 순수 관측, 화면에 안 그린다.
`$5E1A` 쓰기마다 `$20A2`·`$5E1B`·펄스 두 바이트를 같이 남긴다.

★ 그 뒤 `0.2.0-playback-done-latch` · `0.3.0-ac-playback-latch` 가 나왔다.
**rc12 를 시험할 때는 0.3.0 을 쓸 것** (rc12 의 `TEST_IN_MESEN.txt` 참고).
0.1.0 은 관문 쪽을 볼 때만 쓴다.

---

## 6. 스튜디오 — CD-DA 타임라인 (2026-09-07)

싱크 맞추는 중에 화면이 저 혼자 움직이던 것을 고쳤다.

```
원인   재생 틱 → FollowCddaPlayback → 그리드 행 선택 이동 → SelectCddaPartRow
       → UpdateCddaFocusView → SetView()   ★창이 통째로 점프
```

- 확대와 따라가기를 **분리**했다.  `따라가기` 스위치, 기본 꺼짐.
- 지금 말하는 자막은 **표시만** 한다 (캡션 ♪ 딱지 + 블록 아래 노란 밑줄).
- **가로 스크롤 막대** 추가 (확대했을 때만).  휠 = 좌우, Ctrl+휠 = 배율.
- 블록을 누르는 순간 창이 튀던 것도 고쳤다 — `SelectionChanged` 가 `MouseDown`
  도중에 떠서 드래그가 바뀐 좌표계 위에서 시작하고 있었다.
- 편집할 때마다(`RefreshCddaTimeline`) 창이 되돌아가던 것도 멈췄다.
  이제 **고른 조각이 바뀔 때만** 창을 다시 맞춘다.

`snatcher_tool/SnatcherTranslationStudio.exe` 재빌드 완료.
