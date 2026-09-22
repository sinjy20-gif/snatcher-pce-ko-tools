# SNATCHER GFX native POC — 2026-09-08

> **2026-09-09 재판정:** r4도 해결판으로 채택하지 않는다. 공용 타일 업로더에서
> `CD-DA track + 타일 지문`으로 장면을 추측하는 설계는 아직 근거가 부족하다.
> 후속 작업은 `SNATCHER_GFX_NATIVE_REASSESS_2026-09-09.md`에서 시작한다.

## 결론

Lua `GFX/0.3.0`에서 검증하고 실기 통과한 **dedication 한 화면**을 BIOS 상주
네이티브 루틴으로 옮긴 실험 기록이다. 마지막 실패판은 아래 격리 위치에 있다.

`build/patch/_FAILED_EXPERIMENTS_2026-09-09/0.6.3-gfx-native-poc-r4`

Lua 없이 실행하는 POC였으나 실제 플레이에서 게임 그래픽 파손이 확인됐다.
release가 아니며 사용하지 않는다.

> **r3 중단:** 타이틀 / 시작 선택 화면에서 단일 타일 지문이
> 오탐하여 화면 전체를 오염시켰다. 게임/FPS/음악은 계속됐다. r3는 증거 보존만
> 하고 사용하지 않는다. r4는 CD-DA track 문을 추가했다.

## 런타임

- 진입: 뱅크 1 dispatcher 꼬리 `$FC07`의 `LDA $7FDF`를 `JSR $FF27`로 교체
- 트리거: Track 02 `$725C` 업로더 직전 `$7256` 프롤로그를 BIOS `$FF74` 게이트로 교체
- 지문: 업로드 직전 RAM `$3B00`의 원본 타일 `$16A` 앞 16 B
- 장면 문: 게임 드라이버의 현재 CD-DA track `$263B == $17`(BCD)
- 안정 대기: 원본 업로드와 겹치지 않도록 12 frames
- 대상 밖 VDC 접근: 0회
- 전송: 8 tiles/frame = 256 B/frame
- 전체: 136 tiles, 그 뒤 BAT 15 cells
- 같은 업로드 중 phase 1/2면 재무장하지 않고, 완료 후 재진입 시 다시 무장
- 반환: 검증된 VDC ABI `MAWR=$1000`, VWR selected
- 기존 ABI: X/Y 보존, A=`$7FDF`로 반환

코드는 0.6.2에서 실제로 FF인 세 조각에 나눴다.

| 구간 | 용도 | 사용/용량 |
|---|---|---:|
| `$EFB2-$F04D` | tile/BAT injector | 144/156 B |
| `$FC16-$FC76` | AC channel 2/3 helpers | 56/97 B |
| `$FF27-$FFD9` | state machine + track/tile upload gate | 169/179 B |

AC channel 2는 상태, channel 3은 프레임 사이에 유지되는 tile/BAT cursor로
쓴다. 기존 subtitle/CD-DA가 쓰는 channel 0/1은 건드리지 않는다.

### 첫 판·r2·r3 실패와 r4 수정

`0.6.3-gfx-native-poc`는 Mesen에서 **검은 화면, 음악은 계속 재생**으로 실패했다.
CPU/CD 정지가 아니라 영상 경로 파손이다. 첫 판은 Lua의 VRAM 읽기를 네이티브에서도
같은 비용으로 생각하고 전역 dispatcher에서 MARR/VRR을 매 프레임 골랐다. VDC의
이전 MARR/선택 값은 되읽을 수 없으므로 `$1000/VWR` 추정 복원이 부팅 중 전송을
깨뜨렸다.

r2는 VRAM 폴링을 전부 제거했다. 장면별 RAM overlay의 `$725C` 업로더가 정확히
일치하고, dedication 원본 범위의 마지막 타일 `$18C`가 `$3B00`에 남았을 때만
phase 2를 무장한다. 지문이 틀리면 VDC를 한 번도 건드리지 않고 원본 화면으로
지나가는 fail-closed 구조다. 실제 판정은 검은 화면 없이 부팅됐지만 헌사가
일본어로 남았다. 안전성은 복구됐고, 같은 프레임 안에 공용 버퍼가 다시 쓰여
전역 프레임 훅이 마지막 타일을 놓친 것으로 판정했다.

r3는 이미 수집된 `dump/tile_writer_20260905_124849.tsv`의 실제 경로를 쓴다.
Track 02 bank A에 유일한 `$725C` 업로더 직전의 6 B 프롤로그를
`JSR $FF74; NOP; NOP; NOP`로 바꿨다. 업로드마다 한 번 `$3B00`을 Lua 검증
지문 타일 `$16A`와 비교하고, 맞으면
phase 1을 무장한다. 그 뒤 12프레임은 VDC에 접근하지 않고 기다렸다가 phase 2에서
주입한다. 즉 VRAM 폴링도, 업로드 뒤 버퍼 잔존 가정도 없다.

실측에서는 이 16 B가 후반 일반 그래픽에서도 재사용되어 거짓 양성이 났다.
dedication 덤프들의 CD-DA sector 184197–190415는 전부 disc track 17 범위다.
r4는 `$263B == $17`을 먼저 검사하고, 맞을 때만 기존 16 B 타일 지문을
비교한다. `dump/cdda_track_signal_0_4_0_20260907_230750.tsv`의 Mesen 실측에서도
track 전환에 맞춰 `$263B`이 `$21→$17→$18→$19`로 변했고, 같은 시점의
`$26F9`는 raw `$11→$12→$13`이었다. 따라서 장면 문에는 게임 드라이버가 직접
유지하는 BCD 값 `$263B`을 사용한다.

지문 오탐 감사도 했다. `dump/gfx_*.vram.bin` 29개를 전수 검색했을 때 이 16 B는
4개 덤프에서만, 모두 정확히 타일 `$16A`의 시작 위치에 나타났다. 다른 캡처나 다른
타일 위치의 동일 지문은 0건이다.

## 페이로드

- `build/gfx/gfx_screens.bin`
- AC `$1A0000-$1A126D`
- 4,718 B
- SHA-256 `AE1168EB037279E04BE3E3D76A8E0DE2A47835A5F77DB444AB9BE36080A022CE`

subtitle pack 실제 데이터 끝과 ADPCM master `$1E0000` 사이의 FF 간격에 넣었다.
별도 BIOS preload 행은 추가하지 않았다. 현재 loader는 공간이 빠듯하므로 이쪽이
안전하다.

Track24에서 다시 만든 섹터는 51944–51946 세 개뿐이다. `bios_preload.json`의
`relative_sector`는 후속 payload 삽입 전 값이라 현재 Track24와 225 sectors
어긋나 있었다. 빌더는 JSON 위치를 쓰지 않고 user-aligned `SNSB`를 직접 찾아
현재 pack 시작을 정한다.

Track 02는 업로더가 든 raw sector 253 한 개만 다시 만들었다. 원본 19 B 루틴은
전체 Track 02에서 유일하다. `$7256`의 `A4 97 9F 11 14 82`만
`20 74 FF EA EA EA`로 바뀌고 `$725C` 루프는 원형이라 타일당 한 번만 게이트를 탄다.

## 같이 고친 것

- `lua/GFX/0.3.1-inject-from-payload.lua`
  - 예전 `+0 count / +2 rows` 해석을 현재 packer 형식인
    `+0..3 state / +4 count / +6 rows`로 수정
  - native와 같은 8 tiles/frame로 수정
- `tools/patch_track24_subtitle_pack.py`
  - 자막 팩을 다시 구울 때 GFX 영역을 FF로 지우지 않도록 같은 payload를 합성
- `tools/build_gfx_native_dedication.py`
  - payload/빈 공간/hook/Track24 범위/EDC·ECC/기준판 불변을 fail-closed로 검사
  - 완전한 실행 후보 폴더 생성

## 정적 판정

- Python compile 통과
- 세 코드 구간 용량 통과
- `$FC07` 원본 9 B 지문 통과
- BIOS 변경 범위 감사 통과
- Track02 변경 범위는 raw sector 253 하나로 제한
- Track24 변경 범위는 위 세 raw sectors 안으로 제한
- HuC6280 디스어셈블 재검사 통과
- 기존 GFX VRAM 덤프 29개 대상 `$16A` 지문 오탐 0건
- 기준 0.6.2 BIOS/Track02/Track24 해시 불변 확인

후보 해시:

- BIOS `7A238DFF427628003C1C35A3B7EC21DA9C0671F554D54A9A04B04B6122B90978`
- Track02 `E550E6FFE8091D2863AAC23E28E063356D40AFB044D10E5C0A62B4E10CE41DC0`
- Track24 `4C3EAEED7AAC09D2BC5DE43AA5C62C52F90127944E0F1A3BB8B805737A2FF174`

## 최종 판정

r4도 실제 플레이에서 앞 장면부터 게임 그래픽이 심하게 파손됐다. 뒤의 날짜
화면은 새 타일/BAT 업로드 때문에 일시 정상처럼 보였지만 복구된 것이 아니다.
캡처는 `qa/2026-09-08-rc12/captures/038-gfx-native-later-screen-temporarily-normal-suspect.png`에
보존했다.

r1~r4는 모두 `build/patch/_FAILED_EXPERIMENTS_2026-09-09/`로 격리했다. 현재
플레이 기준판 `0.6.3`에는 GFX payload와 실행 훅이 없다. 후속 작업은 장면 전용
식별자를 증명하기 전까지 중단한다.
