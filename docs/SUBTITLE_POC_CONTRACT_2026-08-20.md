# 자막 POC 계약 (2026-08-20)

## 지금 작동하는 범위

`python tools/compile_voice_subtitles.py`는 Studio의 `voice_events.tsv`와
`voice_subtitles.tsv`를 검사하고 `build/subtitles/subtitle_runtime.{json,tsv}`로
컴파일한다. `lua/SUBTITLE_OVERLAY_0.1.3.lua`는 같은 음성 식별 규칙으로 실제 재생
중 자막을 표시한다. 따라서 대사 번역 종료 뒤 Studio에서 자막을 입력하면 데이터는
그대로 런타임 패키지까지 이어진다.

ADPCM 식별자는 실측상 재실행 드리프트가 적은 `끝주소 + 재생률`이며 CDDA는 트랙
지문을 유지한다. 시간은 60 Hz 프레임 정수로 고정한다. 같은 `event_id + part` 중복, 없는 음성 연결, 빈 번역,
음수 시간, 잘못된 지문은 빌드 오류다.

## 디스크 런타임 POC 합격선

BIOS 진입점은 `AD_PLAY $E03C->$F5C6`, 상태 확인은 `AD_STAT $E045->$F6DB`이다.
자막 표에 등록된 음성에만 다음 순서를 실행한다.

1. IRQ1 벡터와 빌린 RAM `$5B80-$5FFF` 1,152바이트를 AC `$1C0000` 예약부로 대피
2. 엔진 설치 및 기존 IRQ1 핸들러 체인
3. AD_STAT 종료 확인
4. 원래 RAM과 IRQ1 벡터를 바이트 단위로 복원

복원 전후 해시가 다르거나, 자막 없는 음성에서 대피가 한 번이라도 실행되면 실패다.
반복 SFX `vDA76A9EB.bin`은 프리로더와 충돌한 실측이 있으므로 등록 대상에서 제외한다.
오프닝 CDDA는 별도 경로인 `CD_PLAY $E012`와 `CD_SUBQ` 호출자 `$6119`를 사용한다.

### 1차 shadow 왕복

`lua/PROBE_SUBTITLE_BORROW_SHADOW_0.1.0.lua`는 등록된 ADPCM이 시작될 때만 대여
후보 1,152바이트를 AC `$1C0000`에 복제한다. 재생 중 해당 범위의 write/exec를 세고
종료 때 RAM과 AC 복사본을 전부 비교한다. `writes=0`, `execs=0`, `diff=0`일 때만
PASS다. 이 판은 게임 RAM을 덮지 않으므로 안전성 확인용이며, PASS 뒤에 실제 엔진
이미지를 설치하는 active 왕복으로 넘어간다.

## 폐기된 구현

`tools/build_subtitle_poc.py`의 `$5C40-$5E1F` 상주 가정과 AC `$011000`은 사용하지
않는다. 전자는 게임 스크립트 VM 스택과 100% 겹치고 후자는 최종 예약부가 아니다.
디스크 패처의 `SNATCHER_SUBS_POC` 차단은 위 왕복 검증이 끝날 때까지 유지한다.
