# SNATCHER 주말 통합 인계서 — 2026-09-05~06

## 0. 시작점

현재 실기 시험판은 `build/patch/0.6.0-rc1` 하나다.

반드시 같은 폴더의 아래 두 파일을 함께 선택하고 전원부터 다시 켠다.

- `Syscard3_galmuri_0.6.0-rc1.pce`
- `Snatcher CD-ROMantic (Japan) [KO].cue`

세이브스테이트와 상태를 바꾸는 Lua는 사용하지 않는다. 실기 합격 전에는 정식
`0.6.0`으로 승격하지 않는다.

## 1. 주말에 닫은 문제

### CD-DA 전용 상주 설계

기존 CD-DA는 ADPCM의 671 B CPU RAM 임대 구조를 물려받아 게임 스크립트 VM
스택과 충돌했다. Track 3 장소 전환에서 게임이 그 RAM을 되찾으면 렌더러와 종료
경로가 함께 깨졌고, UI 미복귀·그래픽 손상·자막 노이즈가 연쇄적으로 발생했다.

현재 설계는 CD-DA 렌더러 코드를 BIOS ROM에 상주시켰고, CD-DA 전용 상태와 작은
데이터 영역만 RAM에 둔다. CD-DA는 더 이상 ADPCM 슬롯의 서명이나 671 B 복사·복원
수명주기를 사용하지 않는다.

사용자 실기 확인:

- 오프닝을 건너뛰지 않고 끝까지 재생한 뒤 ACT 1 정상
- Track 3 정상 진행
- Track 3 접수처·국장실 진입 뒤 남던 복원 노이즈 제거 확인
- Track 5 종료 뒤 UI 정상 복귀
- CD-DA 자막은 같은 문장에서도 누적 싱크 밀림이 관측되지 않음

### CD-DA Track 3 중간 철거

불안정한 레코드 오프셋 대신 안정적인 시작 프레임 493, 1964를 기준으로 중간 철거를
예약한다. 실제 철거 지점은 579f, 2099f다. 다음 자막이 나올 때까지 묵은 줄이 남던
현상을 이 경로에서 없앴다.

### 오프닝 연속 재생 ACT 1 손상

오프닝을 스킵하면 정상이고 자연 재생하면 ACT 1부터 깨지던 문제를 CD-DA 전용 CPU
RAM 캐시로 막았다. 사용자 실기에서 오프닝 자연 재생 정상 확인 완료.

## 2. ADPCM 안전자리 현황

현재 자막을 가진 런타임 키 1,077개는 전부 빌드 가능한 안전자리가 있다.

- 미관측이면서 자막이 있는 항목: 0
- 관측됐지만 안전자리가 전혀 없고 자막이 있는 항목: 0
- 안전자리 하나만 관측되어 실기 확인이 필요한 항목: 12

단일 안전자리 12개:

```
ADPCM_003807_5800_0E  $3A00
ADPCM_00380E_3800_0E  $3A00
ADPCM_003825_B800_0E  $3A00
ADPCM_004098_E800_0E  $3900
ADPCM_005623_FFFF_0E  $4900
ADPCM_005647_D800_0E  $4900
ADPCM_005659_9000_0E  $4900
ADPCM_005660_3800_0E  $4900
ADPCM_00566B_5800_0E  $4900
ADPCM_0062A9_A800_0E  $6A00
ADPCM_0062C9_FFFF_0E  $6A00
ADPCM_0062E0_B000_0E  $6A00
```

`ADPCM_002381_F000_0E`은 관측됐지만 안전자리가 없는 효과음이며 자막이 없다.

중복 꼬리/효과음으로 판단해 자막에서 제거한 항목:

- `ADPCM_008A00_4FFF_0E`
- `ADPCM_008EAE_6FFF_0E`

`ADPCM_008254_FFFF_0E` 1번 자막 끝의 숨은 줄바꿈도 제거했다. 현재 문장은
`모국에서 멀리 떨어져 있던 제이미는` 한 줄이다.

## 3. RC1 데이터와 배치

- 자막 팩: 224,157 B, SHA-256 `1F919885C368277DEB3D0B54201944C14DD40D5FF8147F4D042C363D94CC6746`
- ADPCM 조각 2,408개 / 음성 1,080개
- CD-DA 엔트리 762개
- 길이 초과로 빠진 자막 0개
- ADPCM LBA master는 `$1E0000`
- native directory는 `$1F2800`
- native payload는 `$1F4DF8`~`$1FCC77`
- ADPCM engine은 `$1FE400`
- CD-DA scheduled engine은 `$1FE800`
- CD-DA mini index는 `$1FEB00`
- CD-DA track directory는 `$1FFA00`

RC1 핵심 파일 SHA-256:

```
BIOS    B32BDC06FBA6A4DDE54B5BDDF98C17BBFCD9C90F970F97F56D457C2D7DDB110A
Track24 B3DBB539BC27B6D0A082D2BD5FDBD4CF74B02A0B1054C79C77E4B1C923ACEE39
CUE     934455F721F0869A88FE7A7B5E4F3210E19B91E5A74A50D1F377315A2A22359F
Studio  6DBBB40768EFBDB8B1BEDDF71417A5EA89726F5E6CA904D617299FA0EBFEEAFF
```

## 4. 환경 B에서 우선 확인할 것

1. RC1을 전원 리셋부터 시작한다.
2. ADPCM 단일 안전자리 12개를 실기 확인한다.
3. CD-DA 남은 트랙의 싱크를 맞춘다.
4. 전체를 한 번 더 주행하며 미수집 이벤트를 긁는다.
5. 그래픽 작업과 글자 검색 엔진을 마무리한다.
6. 전체 회귀가 끝나면 RC1 계열을 정식 `0.6.0`으로 승격한다.

## 5. 다시 굽는 절차

스튜디오를 닫은 다음 자막 프론트도어로 새 번호를 만든다.

```
python tools/make_subtitle_build.py <새버전>
python tools/patch_bios_cdda_rom_resident.py <새버전> --write
```

`make_subtitle_build.py` 안에서 자막 정본 동기화, 자막 팩 생성, 디스크 생성,
Track 24 교체, CPU cache 패치가 순서대로 실행된다. 마지막 ROM resident 패치는 현재
별도 단계이므로 빼먹으면 안 된다.

## 6. 함께 읽을 원문 인계서

- `SNATCHER_HANDOFF_20260904_EVENING.md`: 토요일부터 일요일까지 누적된 측정 원문
- `SNATCHER_2026-09-06_NIGHT_HANDOFF.md`: CD-DA 재설계 결론과 당시 원인 사슬
- `RESYNC_TODO_2026-09-05.md`: 토요일 자막 재동기화 메모

