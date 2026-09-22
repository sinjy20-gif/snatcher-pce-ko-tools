# SNATCHER 환경 B → 환경 A 인계 — 2026-09-07

## 먼저 실행할 빌드

- 폴더: `GAME_BUILD/0.6.0-rc3-adpcm-reuse`
- BIOS: `Syscard3_galmuri_0.6.0-rc3-adpcm-reuse.pce`
- 게임: `Snatcher CD-ROMantic (Japan) [KO].cue`
- CHD는 만들지 않았다. CUE와 24개 트랙을 그대로 사용한다.
- 기존 세이브 이름을 유지하도록 게임 CUE와 트랙 이름은 기존과 같다.
- 테스트를 시작할 때는 BIOS와 CUE를 함께 지정하고 전원을 완전히 다시 켠다.

## 오늘 완료한 것

### ADPCM 연속 재생 시 엔진 복사 생략

- ADPCM 자막 엔진 끝에 5바이트 서명 `41 44 37 A4 A5`를 넣었다.
- 다음 ADPCM 자막이 시작될 때 AC의 기존 엔진 서명이 맞으면 671바이트 복사를 생략한다.
- 서명이 없거나 다른 엔진이 올라와 있으면 예전과 똑같이 전체 엔진을 복사한다.
- 종료 구조와 정리 순서는 바꾸지 않았다.
- dispatcher는 2,777바이트이며 한계 2,957바이트 안에 들어간다. 여유는 180바이트다.
- 정적 계산상 연속 ADPCM 한 건마다 약 10,736 CPU cycle, 약 23.6 scanline 분량을 줄인다.

### CD-DA

- Track 20 종료 뒤 같은 트랙 자막이 다시 잡히는 현상에 120프레임 재진입 방지 판정이 들어 있다.
- 오염된 2026-09-07 Track 17 VRAM 덤프 세 개는 안전 위치 계산에서 제외했다.
- CD-DA mini index는 735구간, 3,675바이트로 다시 만들었다.
- Track 17의 안전한 기준 위치 `$7900`을 유지한다.

### 번역 스튜디오

- CD-DA 편집 중 Space와 `.`가 전각으로 들어가던 문제를 고쳤다.
- 셀 복사는 트랙 정보 전체가 아니라 자막 본문만 복사한다.
- ADPCM의 여러 형태 점 세 개를 한 형태로 강제 정규화한다.
- CD-DA 싱크 확대 모드와 F6/F7 미세 이동 기능이 들어 있다.
- 실행 파일은 `snatcher_tool/SnatcherTranslationStudio.exe`다.

### 수집기

- `snatcher_tool/mesen/RUN_2_VOICE_AND_VRAM_MAP_0_4.lua`: 플레이 화면을 가리던 표시를 숨겼다.
- `snatcher_tool/mesen/PROBE_GFX_SCREEN_0_2_0.lua`: Stop 없이 G 키로 화면 VRAM/CRAM을 수집한다. 저부하판 내용은 0.2.1이다.
- 오늘 수집한 GFX 7세트와 색인도 `project/dump`에 넣었다.

## 환경 A 작업 폴더에 반영

1. 이 묶음의 `project` 안 내용을 환경 A의 `C:\snatcher`에 복사해서 덮어쓴다.
2. 이 묶음의 `snatcher_tool` 안 내용을 `C:\snatcher\snatcher_tool`에 복사해서 덮어쓴다.
3. 삭제 동기화는 하지 않는다. 환경 A에만 있는 원본과 백업은 그대로 둔다.
4. 바로 실기 테스트하려면 `GAME_BUILD/0.6.0-rc3-adpcm-reuse`를 사용한다.

## 다음 우선 테스트

1. 국장실처럼 같은 화면에서 ADPCM이 연속되는 구간의 그림 밀림을 확인한다.
2. 마지막 챕터의 장시간 ADPCM 연속 구간을 확인한다.
3. Track 20 종료 뒤 같은 자막이 한 번 더 나오지 않는지 확인한다.
4. CD-DA 전체 싱크 작업을 계속한다.
5. GFX 자료 수집을 계속하고, 수집이 끝나면 네이티브 치환 위치를 확정한다.

## 핵심 검증값

- BIOS SHA-256: `352A600040B34C1E54999387B36FA8CD5CE52714818152C69FAA3135D6E7BD8A`
- Track 24 SHA-256: `B26A42782CC5E8F9066BBFE18A602905AE7B32C0E13CC8442E290E973AB2E8B2`
- CUE SHA-256: `934455F721F0869A88FE7A7B5E4F3210E19B91E5A74A50D1F377315A2A22359F`

