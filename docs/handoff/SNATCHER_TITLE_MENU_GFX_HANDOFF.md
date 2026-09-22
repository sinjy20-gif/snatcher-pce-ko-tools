# SNATCHER 타이틀 메뉴 그래픽 조사 인계서

작성 시점: 2026-08-13  
대상: PC Engine CD-ROM²판 **SNATCHER CD-ROMantic (Japan)**  
목적: 타이틀 메뉴의 일본어 고정 그래픽  
- `初めから`
- `<원문 8자>`

를 한국어
- `처음부터`
- `세이브한 곳에서`

로 교체하기 위한 현재까지의 조사 결과 정리.

---

## 1. 현재 결론

타이틀 메뉴 두 줄은 일반 텍스트 렌더러가 아니라 **스프라이트 그래픽**이다.

Sprite Viewer에서 직접 확인했으며, 커서 삼각형 역시 별도 스프라이트다.

### `처음부터` 쪽 실제 메뉴 스프라이트

커서 제외:

- Sprite 8
  - X = `$70`
  - Tile address = `$6700`
  - Size = `32x32`

- Sprite 6
  - X = `$90`
  - Tile address = `$6800`
  - Size = `32x32`

- Sprite 5
  - X = `$B0`
  - Tile address = `$6E40`
  - Size = `16x32`

커서:

- Sprite 9
  - X = `$58`
  - Tile address = `$5280`
  - Size = `16x16`
  - 흰색 삼각형 선택 커서
  - 선택 항목에 따라 이동함

### `세이브한 곳에서` 쪽

- Sprite 7
  - X = `$70`
  - Tile address = `$6900`
  - Size = `32x32`

- Sprite 4
  - X = `$90`
  - Tile address = `$6A00`
  - Size = `32x32`

- Sprite 3
  - X = `$B0`
  - Tile address = `$6D00`
  - Size = `32x32`

- Sprite 2
  - X = `$D0`
  - Tile address = `$6680`
  - Size = `32x16`

X가 32픽셀씩 증가하므로 각 스프라이트 블록이 이어져 한 줄 메뉴 그래픽을 구성하는 형태로 보인다.

---

## 2. VRAM 추적 결과

VRAM `$6700` Write breakpoint를 걸었을 때 두 경로가 잡혔다.

### 직접적인 VRAM 전송 루프 후보

```asm
7256 LDY $97
7258 BBS1 $11,$726F
725B CLX

725C LDA $3B00,X
725F STA VDC_DATA_LO_0002

7262 INX
7263 LDA $3B00,X
7266 STA VDC_DATA_HI_0003

7269 INX
726A CPX #$20
726C BCC $725C
726E RTS
```

핵심:

- `$3B00` CPU RAM 버퍼에서 읽음
- VDC DATA low/high로 전송
- VRAM `$6700` 쪽 메뉴 스프라이트 데이터에 실제로 닿는 경로
- `$3B00`이 중요한 작업 버퍼임은 확정

---

## 3. `$3B00` 버퍼 추적

CPU Memory Write breakpoint를 `$3B00`에 걸었을 때 여러 루틴이 잡혔다.

중요한 점:

**`$3B00`은 하나의 전용 버퍼가 아니라 여러 루틴이 공용으로 사용하는 작업 영역이다.**

따라서 `$3B00` Write 아무거나 잡으면 메뉴 그래픽 전용 경로가 아닌 다른 초기화/변환 루틴도 같이 걸린다.

---

## 4. CD-ROM 읽기 루틴 발견

다음 코드가 `$3B00`을 채우는 경로 중 하나로 확인됨.

```asm
EA79  LDA $1800
EA7C  AND #$F8
EA7E  STA $227A

EA81  CMP #$C8
EA83  BEQ $EA8B

EA85  CMP #$D8
EA87  BEQ $EABD
EA89  BRA $EA79

EA8B  LDA $F8
EA8D  ORA $F9
EA8F  BEQ $EAB5

EA91  LDX #$03
EA93  DEX
EA94  BNE $EA93

EA96  CLY
EA97  LDX #$08

EA99  LDA $1808
EA9C  STA ($FA),Y

EA9E  LDA $F8
EAA0  BNE $EAA4
EAA2  DEC $F9

EAA4  DEC
EAA5  STA $F8
EAA7  ORA $F9
EAA9  BEQ $EAB5

EAAB  INY
EAAC  BNE $EA99

EAAE  INC $FB
EAB0  DEX
EAB1  BNE $EA99

EAB3  BRA $EA79
```

현재 해석:

- `$1800`대는 PCE CD-ROM 인터페이스 계열로 보임
- `$1808`을 반복해서 읽음
- `($FA),Y`가 가리키는 RAM으로 순차 저장
- breakpoint 당시 `$FA:$FB = $3B00`

즉 대략:

```text
CD-ROM 데이터 입력
  ↓
$1808
  ↓
EA99 LDA $1808
EA9C STA ($FA),Y
  ↓
$3B00 계열 작업 버퍼
```

주의:

`$1808`은 그래픽 원본 RAM 주소가 아니라 **CD-ROM 데이터 입력 포트 성격**으로 보는 것이 자연스럽다.

---

## 5. CD sector 추적용 Lua

작성한 파일:

`PROBE_TITLE_GFX_SECTOR_v2.lua`

기능:

- `$3B00~$3B1F` CPU Write 감시
- write burst 첫 시점에
  - frame
  - `cdrom.scsi.sector`
  - address
  - value
  기록

출력:

`C:\snatcher\dump\title_gfx_sector_probe.tsv`

실행 로그:

```text
TITLE GFX LOAD[1]  frame=0    sector=0
TITLE GFX LOAD[2]  frame=89   sector=4178
TITLE GFX LOAD[3]  frame=133  sector=4211
TITLE GFX LOAD[4]  frame=205  sector=4303
TITLE GFX LOAD[5]  frame=248  sector=4303
TITLE GFX LOAD[6]  frame=371  sector=4303
TITLE GFX LOAD[7]  frame=402  sector=4303
TITLE GFX LOAD[8]  frame=729  sector=4303
TITLE GFX LOAD[9]  frame=1066 sector=14394
TITLE GFX LOAD[10] frame=1096 sector=14394
```

사용자 체감상 **frame 1066~1096이 타이틀 메뉴가 나타나는 시점과 일치**.

따라서:

### 핵심 후보 sector

`sector = 14394`

타이틀 메뉴 그래픽 관련 CD read일 가능성이 매우 높다.

---

## 6. CUE / Track 구조

CUE:

```cue
FILE "Snatcher CD-ROMantic (Japan) (Track 01).bin" BINARY
  TRACK 01 AUDIO
    INDEX 01 00:00:00

FILE "Snatcher CD-ROMantic (Japan) (Track 02).bin" BINARY
  TRACK 02 MODE1/2352
    INDEX 00 00:00:00
    INDEX 01 00:03:00
```

후반에 Track 24도 MODE1/2352이지만 현재 타이틀 메뉴는 Track 02 쪽으로 보고 있음.

Track 01.bin 크기:

`9,288,048 bytes`

raw sector 2352 기준:

`9,288,048 / 2352 = 3949 sectors`

즉 Mesen `cdrom.scsi.sector=14394`가 디스크 전체 기준 sector라면 Track 02.bin 내부 raw sector는:

```text
14394 - 3949 = 10445
```

Track 02.bin 파일 오프셋:

```text
10445 × 2352
= 24,566,640
= 0x0176DB70
```

HxD에서 확인한 위치:

`0x0176DB70`

실제로 raw MODE1 sector header가 보였음:

```text
00 FF FF FF FF FF FF FF FF FF FF 00 03 13 69 01
```

따라서:

- raw sector start = `0x0176DB70`
- MODE1 user data start = `0x0176DB80`

이 오프셋 계산은 상당히 신뢰 가능.

---

## 7. 중요한 관찰: BIN 원본 ≠ `$3B00` 내용

CPU Memory `$3B00`에서 실제로 본 예시:

```text
3B00  03 E0 07 C3 07 03 01 4C 9C 01 80 80 01 04 20 60
3B10  06 B0 0D F0 0F 6A 5E 7A 56 F0 0F B0 0D 60 06 04
3B20  20 80 01 01 80 46 98 82 41 04 20 40 02 D0 0B A8
...
```

이 바이트열을 HxD에서 Track 02.bin 전체 검색했지만 **그대로는 잡히지 않음**.

따라서:

```text
CD 원본 데이터
  ↓
[중간 가공 / 변환 / 패킹 해제 / 그래픽 재조립]
  ↓
$3B00
  ↓
VRAM
```

일 가능성이 높다.

즉 `$3B00`은 CD raw 그래픽 원본이 아니다.

---

## 8. 그래픽 변환 루틴 후보

다음 루틴이 `$3B00,X`를 생성함.

```asm
7201  BBR0 $11,$721E
7204  LSR A
7205  ROL $07
7207  LSR A
7208  ROL $07
720A  LSR A
720B  ROL $07
...
7219  LSR A
721C  ROL $07

721E  LDX $CC
7220  STA $3B00,X
7223  INC $CC
7225  CPX #$1F
```

특징:

- `LSR A`
- `ROL $07`

을 반복
- 비트를 하나씩 분리/재조립하는 형태
- 결과를 `$3B00,X`에 저장

따라서 이 경로는 **단순 CD copy가 아니라 비트 단위 변환 루틴**임은 거의 확실.

다만 아직 미확정:

- 실제 압축 해제
- PCE 스프라이트 비트플레인 변환
- 전용 그래픽 패킹 해제
- 타일 재배열

중 무엇인지는 확정하지 못함.

---

## 9. 별도 대량 전송 루틴

다음 코드도 확인됨.

```asm
4051  TAI $444C,$22D0,#$1CB0
4058  JSR $4880
```

`0x1CB0 = 7344 bytes`

즉 타이틀 관련 자원을 **몇 KB 단위 블록으로 대량 처리하는 경로**가 존재.

메뉴 두 줄만 별도 압축했다기보다, 타이틀 그래픽 자원 전체를 한 묶음으로 읽고 가공하는 구조일 가능성이 높다.

---

## 10. `$3B00` 공용 버퍼 관련 추가 코드

다음 코드도 확인됨.

```asm
4785  STA $00
4787  STA $01

478A  LDA ($00),Y
478C  STA $02

478E  INY
478F  LDA ($00),Y
4791  STA $03

4795  JMP ($2602)
```

당시 `$00/$01`이 `$3Bxx`를 가리킴.

또:

```asm
47AF  CLA
47B0  STA ($00)
47B1  INC $00
47B3  BNE ...
```

형태의 `$3B00` 영역 초기화 루틴도 존재.

따라서 `$3B00`은 여러 타이틀/그래픽 루틴이 공용으로 사용하는 scratch/work buffer로 보는 것이 타당.

---

## 11. 현재 가장 유력한 구조

현재까지의 최종 구조 가설:

```text
Track 02.bin
sector 14394 부근
(raw offset 약 0x0176DB70)
        ↓
PCE CD-ROM read
        ↓
$1808 data input
        ↓
중간 RAM / 타이틀 리소스
        ↓
비트 단위 변환 / 그래픽 포맷 처리
        ↓
$3B00 work buffer
        ↓
$725C 계열 VDC transfer
        ↓
VRAM
$6700 / $6800 / $6900 / $6A00 / $6D00 / $6E40 ...
        ↓
Sprite
        ↓
타이틀 메뉴
```

---

## 12. 팔레트 / 색 처리

타이틀 메뉴 스프라이트는 Sprite Viewer에서 별도 palette index를 사용함.

예시:

- Palette index = 3
- Palette address = `$130`

따라서 그래픽 데이터 자체에 RGB가 직접 박혀 있는 것이 아니라, 각 픽셀이 **팔레트 인덱스**를 사용하고 실제 색은 별도 palette data에서 결정되는 구조로 봄.

한글화 시에는 원본 메뉴의 palette를 그대로 재사용하는 방향이 가장 좋다.

즉:

- 팔레트 자체 수정 불필요
- 원본과 같은 pixel index 패턴 사용
- 새 한글 글자도 기존 outline / highlight / shadow index를 그대로 대응

하면 원본 색감을 유지할 수 있음.

---

## 13. 실제 한글 그래픽 제작 방향

메뉴 원본 공간은 이미 확보되어 있다.

### 위 메뉴

실사용 폭:

- 32 + 32 + 16 = 80 px

### 아래 메뉴

실사용 폭:

- 32 + 32 + 32 + 32 = 128 px

따라서:

- `처음부터`
- `세이브한 곳에서`

를 원본 영역 안에 맞춰 픽셀아트로 제작한 뒤,
원본 palette index에 맞춘 PCE sprite 데이터로 변환하면 된다.

중요:

**압축이 아니라 단순 그래픽 포맷 변환이라면, 원본 변환 루틴을 완전히 역공학할 필요 없이 한글 이미지를 같은 최종 포맷으로 인코딩해 원본 데이터 자리에 넣는 방식이 가능할 수 있다.**

---

## 14. 다음 조사 우선순위

### 1순위

`7201~7225` 루틴 진입 직전의 입력값과 데이터 source 추적.

특히 확인할 것:

- A는 어디서 로드되는가
- `$11` 역할
- `$07` 역할
- `$CC` index
- 변환 입력 버퍼 주소

목적:

**실제 압축 해제인지 단순 bitplane/graphics conversion인지 판별**

### 2순위

sector 14394 부근 CD raw data가 어느 중간 RAM으로 들어가는지 정확히 추적.

### 3순위

VRAM 최종 데이터 덤프 → PCE sprite bitmap으로 직접 복원.

가능하면 원본 일본어 메뉴 그래픽을 PNG 등으로 추출해
그 스타일을 그대로 참고해 한글 픽셀 그래픽 제작.

### 4순위

한국어 메뉴 그래픽을 PCE sprite 형식으로 인코딩하고,
실기/에뮬에서 원본 tile 영역에 런타임 overwrite 테스트.

이 테스트가 성공하면 디스크 원본 구조를 완전히 이해하기 전에
최종 패치 방식의 feasibility를 증명할 수 있음.

---

## 15. 현재 판단

타이틀 메뉴 두 줄이 예상보다 어려운 이유는 일반 문자열이 아니라:

- CD 자원
- 스프라이트
- VRAM
- 작업 RAM
- 비트 변환

경로를 타는 **고정 그래픽 리소스**이기 때문.

하지만 이미 다음은 확정 또는 강하게 좁혀짐:

- 스프라이트 구성
- 메뉴별 VRAM tile address
- `$3B00` work buffer
- VDC 전송 루틴
- CD-ROM read 루틴
- 타이틀 시점 sector `14394`
- Track 02 raw offset `0x0176DB70` 부근
- `$3B00`에 오기 전 데이터 변환 존재 가능성

따라서 현재 단계는 “어디 있는지 모르는 상태”가 아니라,

**원본 데이터의 최종 변환 포맷만 풀면 교체 가능한 상태에 가까움.**

---

## 16. 참고: 오프닝 CD AUDIO 조사 결과

별도 조사에서 오프닝 나레이션/음성은 기존 ADPCM collector로 잡히지 않고,
Mesen의:

`cdrom.audioPlayer.currentSector`

변화를 감시하면 CD AUDIO 재생을 잡을 수 있었음.

오프닝 본편 CD AUDIO:

```text
CD AUDIO START frame=2331 sector=184018
CD AUDIO END   frame=10283 sector=193971
duration=132.533s
```

따라서 오프닝 자막은:

```text
main CD audio START
→ subtitle timer = 0
→ timecode table
→ CD audio END
```

구조로 구현 가능.

이 내용은 타이틀 메뉴와 직접 관련은 없지만 같은 PCE CD-ROM 경로 조사에서 확보한 참고 정보임.

---

## 17. 인계 시 한 줄 요약

> 타이틀 메뉴는 텍스트가 아니라 Sprite 그래픽이다. 메뉴 VRAM은 `$6700/$6800/$6E40` 및 `$6900/$6A00/$6D00/$6680`, 작업 버퍼는 `$3B00`, CD read는 `$1808`, 타이틀 시점 Mesen sector는 `14394`, Track 02 raw offset은 약 `0x0176DB70`. `$3B00` 데이터가 BIN에서 그대로 안 잡히므로 중간 비트/그래픽 변환이 있으며, `7201~7225`의 `LSR A / ROL $07 → STA $3B00,X` 루틴이 핵심 후보다.

---

## 18. 추가 결론: `$3B00 → $725C → VRAM` 경계에서 우회 가능성

추가 추적 결과, 현재 가장 실용적인 패치 후보가 하나 더 보임.

### 확인된 흐름

그래픽 변환 쪽에서는:

```asm
7204  LSR A
7205  ROL $07
...
721E  LDX $CC
7220  STA $3B00,X
7223  INC $CC
```

형태로 변환된 바이트를 `$3B00` 작업 버퍼에 축적함.

그 뒤 VRAM 전송 쪽에서는:

```asm
725C  LDA $3B00,X
725F  STA VDC_DATA_LO_0002

7262  INX
7263  LDA $3B00,X
7266  STA VDC_DATA_HI_0003

7269  INX
726A  CPX #$20
726C  BCC $725C
726E  RTS
```

형태로 `$3B00` 내용을 읽어서 VDC data register로 보내고 있음.

따라서 현재 구조는 대략:

```text
CD 원본 / 타이틀 리소스
        ↓
비트/그래픽 변환
        ↓
$3B00 작업 버퍼
        ↓
$725C 전송 루틴
        ↓
VDC
        ↓
VRAM
        ↓
Sprite 표시
```

### 중요한 해석

`$3B00`에 있는 데이터는 화면에 보이는 PNG 같은 “완성 이미지”라기보다,

**VRAM으로 바로 보낼 수 있는 스프라이트/타일용 바이트 데이터가 이미 완성된 상태**

에 가깝다고 보는 것이 적절함.

즉 `$725C`는 사실상:

> `$3B00`에 준비된 그래픽 데이터를 VRAM으로 올리는 출구

역할을 하는 것으로 보임.

---

## 19. 실용적 패치 전략 후보

### 전략 A — `$725C` 진입 직전 `$3B00` 교체

가장 유력한 우회 방법:

```text
원본 변환 루틴이 $3B00 생성
        ↓
[한국어 패치 훅]
$3B00 내용을 한국어 스프라이트 데이터로 교체
        ↓
원본 $725C 루틴 그대로 사용
        ↓
VRAM
```

이 방법의 장점:

- VDC register write 로직을 새로 구현할 필요 없음
- 기존 VRAM 전송 타이밍을 그대로 재사용 가능
- CD 원본 압축/패킹 형식을 완전히 해독하지 않아도 될 가능성 있음
- 기존 게임의 VRAM 목적지와 sprite 배치를 그대로 사용 가능
- 팔레트 역시 원본 것을 그대로 재사용 가능

즉 한글 그래픽을 최종 PCE sprite/VRAM 형식으로만 만들 수 있다면,
`$3B00`을 갈아끼우는 것만으로 끝날 가능성이 있음.

### 전략 B — `$725C` 자체를 후킹

또 다른 방법:

```text
725C 진입
  ↓
원본 $3B00 대신
한국어 그래픽 데이터 source를 읽도록 변경
  ↓
기존 VDC 전송
```

하지만 이 경우 원본 루틴의 레지스터/타이밍/호출 조건을 더 정확히 보존해야 하므로,

**우선순위는 전략 A (`$3B00` overwrite) 쪽이 더 높음.**

---

## 20. 이 우회 전략을 확정하기 위해 필요한 다음 확인

다음만 추가로 확인하면 됨.

### 1. `$725C` 호출 횟수

타이틀 메뉴가 나타날 때 `$725C`가 총 몇 번 호출되는지 확인.

### 2. 각 호출의 VRAM 목적지

각 호출이 다음 중 어디를 대상으로 하는지 매칭:

```text
$6700
$6800
$6E40

$6900
$6A00
$6D00
$6680
```

### 3. 호출당 `$3B00` 데이터 범위

각 `$725C` 호출에서 `$3B00`의 어느 바이트를 몇 바이트 전송하는지 확인.

현재 보이는 루프는 `CPX #$20`이므로
해당 호출 단위에서는 0x20 bytes를 다루는 것으로 보임.

단, 하나의 스프라이트 블록 전체가 여러 번에 나뉘어 전송될 수 있으므로
호출 단위와 Sprite tile block 단위가 1:1이라고 단정하지 말 것.

### 4. 메뉴 전용 호출 식별

`$725C`가 타이틀 외 다른 그래픽에도 쓰이는 공용 루틴일 가능성이 있으므로,
다음 조건을 함께 보면 좋음.

- frame
- 현재 VRAM write address
- caller PC
- 타이틀 진입 시점

이 조합으로 메뉴 전용 호출을 특정해야 함.

---

## 21. 현재 가장 현실적인 구현 방향

원본 BIN의 그래픽 패킹 구조를 완전히 해독하는 방식보다,

**최종 변환이 끝난 `$3B00`과 VRAM 전송 루틴 `$725C` 사이에서 한국어 데이터로 교체**

하는 방식이 현재 가장 빠르고 현실적인 후보임.

즉 목표는:

```text
한국어 메뉴 픽셀아트 제작
        ↓
PCE sprite/VRAM용 최종 바이트로 변환
        ↓
타이틀 메뉴용 $3B00 생성 시점에 overwrite
        ↓
기존 $725C 루틴 사용
        ↓
기존 palette + 기존 sprite 배치 그대로 출력
```

이 구조가 성립하면:

- 원본 압축 형식 해독 불필요
- CD sector 원본 수정 불필요할 수 있음
- VDC 전송 루틴 재작성 불필요
- 팔레트 수정 불필요

즉 타이틀 메뉴 한글화 난이도를 크게 낮출 수 있음.

---

## 22. 업데이트된 핵심 한 줄 요약

> 타이틀 메뉴는 Sprite 고정 그래픽이며, CD sector `14394` 부근에서 로드된 자원이 변환되어 `$3B00`에 VRAM-ready 형태로 만들어지고, `$725C` 루틴이 `$3B00`을 VDC/VRAM으로 전송하는 구조가 유력하다. 따라서 원본 패킹을 전부 해독하지 않고도 `$725C` 직전 `$3B00`을 한국어 스프라이트 데이터로 overwrite하는 우회 패치가 가장 실용적인 후보로 보인다.

