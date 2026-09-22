# SNATCHER ADPCM 렌더러 기준 동결 — 현행 native는 A972 엔진 유지 (2026-09-02)

## 결론

현재 ADPCM native 전체화의 렌더링 기준은 아래 **A9722A5F 세대 653 B 엔진**으로
확정했다. 사용자가 `ADPCM_ONLY_0.4.6.63`에서 육안으로 “이 엔진이야, 겁나
깨끗함”이라고 판정했다.

```text
native build build/patch/0.4.6.64/
ADPCM probe  build/patch/TEST/ADPCM_ONLY_0.4.6.64/
pack         build/cutscene_subs/subtitle_pack.bin                  (A9722A5F)
renderer     build/cutscene_subs/engine_ac_lua_frame_rearm_A9722A5F_6600.bin
native dir   build/cutscene_subs/adpcm_native_subtitle_dir_A9722A5F.bin
payload      build/cutscene_subs/adpcm_native_subtitle_payload_A9722A5F.bin
```

이 엔진은 내부 653 B renderer를 유지한 현행 native pack 세대다. ADPCM-only
디스패처는 1,003 key를 무Lua로 무장한다. 렌더러를 다른 653 B 파일로 바꾸지 않는다.

## 동결 식별값

| 자산 | 값 |
|---|---|
| subtitle pack | 191,521 B |
| pack SHA-256 | `A9722A5F930AA578C841B63A3E27BE9A97A416AE7848D8AC9BFBE66E3532E6E1` |
| renderer | 653 B |
| renderer SHA-256 | `76F6725ED25D678643F5CDFD75012A79011A9D84198385F34148E4997830C6A3` |
| ADPCM native directory | 1,003 routes / 8,712 B |
| ADPCM native payload | 27,150 B |
| renderer Track 24 위치 | sector 51905 (`0.4.6.63` 및 `0.4.6.64` byte-identical) |

## 재현 방법

1. `build/patch/TEST/ADPCM_ONLY_0.4.6.64/`의 ADPCM-only BIOS를 Mesen에 건다.
2. `build/patch/0.4.6.64/`의 `[KO].cue`를 연다.
3. Power Cycle 한다. **state-changing Lua는 로드하지 않는다.**

정상 로그의 핵심:

```text
ADPCM-only BIOS + 0.4.6.64 CUE
서로 다른 ADPCM 대사에서 native 자막 표시
다조각 음성 순차 전환 및 종료 뒤 UI 정상 복귀
```

이 시험판은 CD-DA dispatch만 막고 ADPCM native route 전체(1,003 key)는 유지한다.

## 옛 8F20 기준의 용도

`0.5.109.lua`와 `0.4.6.22`는 과거 국장실/50-key Lua 기준을 재현하기 위해 보존한다.
그 체인은 `8F20AF38` pack 및 옛 12-hex 50-key 표와 한 세대다.

옛 표와 현행 이름형 표를 섞으면 다음처럼 Lua 기준은 안전 base를 찾지 못해
fail-closed한다.

```text
MATCH 00D00E437790
MAP SKIP 00D00E437790
```

`0.5.109.lua`는 현행 파일을 되돌리지 않고 옛 세대만 독립 재현한다. 이는 역사적
비교 기준이며, 현재 native build의 renderer를 8F20 파일로 교체하라는 뜻이 아니다.

## 이후 ADPCM 네이티브화의 범위

**유지할 것**

- 653 B renderer의 글리프 렌더링
- 다조각 stage 재무장
- fragment/end SATB 및 Sprite RAM 정리
- VDC MAWR/VWR 재무장 순서
- helper의 VRAM save/render/restore 계약

**네이티브로 일반화할 것**

```text
ADPCM 시작 LBA
  → 전체 route 조회
  → 해당 record/mini schedule 조회
  → 해당 runtime key의 검증 VRAM base 설치
  → state 1
  → 기존 653 B renderer 실행
```

즉 전체화의 대상은 **감지·조회·입력 전달부**뿐이다. `.42`는 이 경로를
`LBA $003083` 한 음성에 대해 무Lua로 검증한 POC이며, 현행 A972 renderer를
교체할 근거가 아니다.

## 주의

- A972 pack과 A972 engine은 record/glyph offset이 결합되어 있다. 다른 세대와 섞지 않는다.
- 8F20은 옛 50-key 시각 기준이고 A972는 현행 native 전체화 기준이다. 서로 교차하지 않는다.
- `.64` 재빌드 때는 `--tag A9722A5F`로 dir/payload/engine을 함께 고정한다.
- 전체 키로 늘릴 때도 각 키의 VRAM base는 실측 검증 후에만 gate를 연다.
