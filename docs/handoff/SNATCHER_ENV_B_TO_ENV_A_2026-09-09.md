# 환경 A에서 여기서부터 — 2026-09-09

## 오늘 뭐가 닫혔나

```
자막      전량 완료.  0.6.4 로 구웠다 (ADPCM 1,081키 · CD-DA 765줄 · mini 738구간)
CD-DA     구간표 꼬리가 자막 3~4줄을 조용히 버리던 구멍을 막았다
GFX       MPR7 뱅크는 확정(26,576/26,576).  ⚠ 그런데 r5 도 깨졌다 -- 원인이 하나 더 있다
```

자세한 건 `project/docs/handoff/SNATCHER_2026-09-09_DAY.md` 하나에 다 있다.

## ⚠ 먼저: 오디오 트랙이 안 들어 있다

Track 01 과 03~23 은 원본과 바이트가 같고 합쳐서 800 MB 가 넘어서 뺐다.
환경 A의 **기존 빌드 폴더에서 복사**해 채워야 CUE 가 열린다.

```
환경 A의 아무 빌드 폴더  ->  GAME_BUILD/0.6.4/
                     ->  GAME_BUILD/0.6.3-gfx-native-r5/
   Snatcher CD-ROMantic (Japan) (Track 01).bin
   Snatcher CD-ROMantic (Japan) (Track 03~23).bin
```

`Track 02` 는 두 빌드가 **바이트 동일**이라 `0.6.4` 쪽에만 넣었다.
`0.6.3-gfx-native-r5` 로도 같은 파일을 복사하면 된다.

## 1) GFX — ⚠ 결론이 뒤집혔다.  진단판부터 돌려라

`GAME_BUILD/0.6.3-gfx-native-r5`

낮에 "r1~r4 실패 원인 = MPR7 뱅크" 로 확정했는데, **Track 02 를 한 바이트도
안 건드린 r5 도 부팅부터 화면 전체가 타일 쓰레기로 깨졌다.**
MPR7 실측은 여전히 맞다 (그 훅도 깨져 있었다).  다만 **유일한 원인이 아니었다.**

용의자 둘이 남았고, BIOS 두 장이 정확히 반을 가른다.  같은 폴더에 둘 다 있다.

```
Syscard3_galmuri_0.6.3-gfx-r5-nohook.pce   ← ★먼저 이걸로
     우리 코드는 다 들어 있는데 $FC07 훅만 안 심었다 = 한 번도 안 돈다

Syscard3_galmuri_0.6.3-gfx-native-r5.pce   ← 낮에 깨진 그것
```

**nohook 판 하나만 부팅해보면 끝난다.**

```
nohook 도 깨진다  -> A.  BIOS 굴이 실제로는 안 비어 있다
                        ($EFB2 / $FC16 / $FF27 -- FF 라고 안 쓰는 자리가 아니다.
                         $ECF9 꼬리 386 B 가 이미 그랬다)
                        자리를 다시 찾아야 한다

nohook 은 멀쩡  -> B.  실행이 문제다.  tick 이 **초기화 안 된 AC 상태**를 믿는다
                        상태 4 B 는 Track24 선적재로 AC $1A0000 에 들어오는데,
                        그 전에 tick 이 돌면 phase 가 쓰레기다.  2 로 읽히면
                        injector 가 부팅부터 VRAM 을 칠한다 -- 그 사진 그대로다
                        고치는 법도 정해져 있다 (아래)
```

B 면 고침은 짧다: 상태 블록에 이미 있는 `$1A0006:07 = A0 16` (지문 VRAM 주소,
`validate_payload` 가 검사하는 값) 을 tick 첫머리에서 확인하고 다르면 즉시 나간다.
선적재 전에는 절대 통과 못 한다.

⚠ 두 BIOS 는 Track 02/24 가 완전히 같다.  **.pce 만 바꿔 끼우면 된다.**
⚠ Mesen 완전히 껐다 켜고 세이브스테이트 물리지 마라.  Lua 도 올리지 마라.

자세한 경위는 `project/docs/handoff/SNATCHER_2026-09-09_DAY.md` §9.

## 2) 0.6.4 — 실기 (RetroArch/Beetle)

`GAME_BUILD/0.6.4`

★★ **트랙 9 · 11 · 13** 을 특히 봐라.  안전자리가 관찰된 창에서만 검증됐다
(각각 미관찰 창 2 / 3 / 1 개).  그 트랙 자막이 쓰레기 타일로 보이면 그게 원인이다.
트랙 11 끝쪽 자막 3 줄은 **오늘 처음 실린 것**이라 특히 봐야 한다.

## 3) 환경 A의 작업 폴더 갱신

- `project` 안을 환경 A의 `C:\snatcher` 에 덮어쓴다
- `snatcher_tool` 안을 환경 A의 `C:\snatcher\snatcher_tool` 에 덮어쓴다
- **삭제 동기화는 하지 않는다**
- `MEMORY` 는 `%USERPROFILE%\.claude\projects\C--snatcher\memory` 로

## 4) 오늘 새로 생긴 것

```
lua/GFX/0.5.0-tick-can-see.lua        tick 이 $3B00 지문을 볼 수 있나  -> 못 본다
lua/GFX/0.5.1-burst-frame-map.lua     덩어리 <-> 프레임 대응
lua/GFX/0.5.2-cdread-census.lua       CD_READ 전수  -> 위치로는 화면을 못 가른다
lua/GFX/0.5.3-zp-discriminator.lua    ★관문을 찾아낸 것.  두 판 돌려 대조했다
tools/build_gfx_native_dedication_r5.py
docs/handoff/SNATCHER_2026-09-09_DAY.md
docs/handoff/SNATCHER_ANDROID_BEETLE_PCE_BOOT_PROBE_PLAN_2026-09-09.md
```

`project/dump/*20260909*` 가 관문 값의 근거다.  버리지 마라.

## 5) Android Beetle PCE 프로브 — `PROBE_ANDROID/`

⚠ DAY 문서(16:44)보다 **뒤에** 나온 것들이라 그 문서엔 안 적혀 있다.
   계획서의 "아직 빌드 안 했다" 도 낡았다 -- 코어가 넷 나왔다.

```
cores/          arm64-v8a 프로브 코어 4 개 + 대조군(손 안 댄 코어를 이름만 바꾼 것) 1 개
                ★최신은 TEXT_SCAN_PROBE_v3 (17:15)
observations/   프로브 주행 TSV 2 개.  서로 다른 주행이다 -- 합치지 말 것
README.md       무엇을 쫓는 문제인지 · 코어 순서 · 원본 자리
```

쫓는 것은 **Android 의 Beetle PCE 에서만** 초기 부팅이 실패하는 문제다.
Beetle SuperGrafx · Geargrafx · PC Beetle PCE 는 다 정상이다.
밀림/흔들림 · ADPCM 뒤 일본어 자막 · 소프트리셋 AC 재적재 와 **섞지 말 것**.

코어 소스(`build/research/beetle-pce-libretro`, shallow clone
`6d6a35eb802e8ff3479f383fff08975842c7376d`)와 빌드 산출물은 크고 되살릴 수
있어서 안 실었다.  환경 A에서 코어를 다시 고치려면 그 commit 으로 clone 부터.

