# SNATCHER 처음부터 재수집 인계 — 2026-08-25

## 현재 목표

현행 번역 마스터가 반영된 `0.4.5.9 subtitle collection`으로 처음부터 끝까지 다시
플레이한다. 화면에 실제로 일본어가 남은 완성 레코드만 따로 잡고, 같은 플레이에서
ADPCM 음성 BIN과 자막 엔진용 6바이트 키, CD-DA 재생 구간을 새 기준 로그로 모은다.

## 실행 조합

- CUE: `build/patch/0.4.5.9-subtitle-collection/Snatcher CD-ROMantic (Japan) [KO 0.4.5.9 subtitle collection].cue`
- BIOS: `build/bios_font/Syscard3_galmuri_0_4_5_9_subtitle_collection.pce`
- BIOS SHA-256: `32B018C5EC9A2DF6DB887D1C4D6E85442F68BE5663FE5BF47E7100256BA08621`
- 미수집 대사 Lua: `snatcher_tool/mesen/COLLECT_MISSING_TEXT_0_1_0.lua`
- 음성 Lua: `snatcher_tool/mesen/COLLECT_VOICE_KEYS_AUDIO_0_1_2.lua`

두 Lua는 각각 별도 Script Window에서 동시에 실행한다. 둘 다 self-contained이며
`C:/snatcher/lua`의 다른 파일을 불러오지 않는다. 음성 `0.1.0`과 `0.1.1`은
사용하지 않는다.

## 출력과 판정

- 일본어 잔존: `snatcher_tool/logs/runtime_missing_text_raw_v010.tsv`
  - 한국어 포인터 치환이 실제 실패한 `changed=no` 완성 레코드만 기록한다.
  - 레코드 순서·꼬리행·앞 공백·`source_hex`를 보존한다.
  - 현재처럼 화면에 일본어가 없으면 헤더 한 줄만 있는 것이 정상이다.
- 음성 이벤트: `snatcher_tool/logs/voice_key_events_raw_v012.tsv`
- 새 ADPCM BIN: `snatcher_tool/logs/voice_clips_v012_fresh/`
  - START/END, 섹터, 주소, 길이, 재생률, BIN 이름을 같은 이벤트 ID로 묶는다.
  - 6바이트 키는 `sector u24 + endAddress u16 + rate u8` 리틀엔디언이다.
  - `endAddress = (readAddress + audioLength) & $FFFF`이다.
  - `writeAddress`는 참고 열로만 남긴다.
- CD-DA는 BIN을 뜨지 않고 전진한 sector 구간과 지속 프레임을 기록한다.

## 0.1.0/0.1.1 폐기 이유와 검증 결과

음성 0.1.0은 BIN과 START/END는 정확했지만 키 가운데 2바이트에 `writeAddress`를
썼다. 대부분 같아 보이나 `$003143`처럼 64KiB 래핑되는 음성에서 엔진 키와
달라진다. 0.1.1에서 끝주소로 수정하고 출력도 v011로 완전히 분리했다.

0.1.1 재시작 시험에서는 같은 키 `ADPCM_003083_5800_0E`가 감지 프레임 차이로
`readAddress`가 4 B 이동해, 한 BIN이 다른 BIN의 완전한 suffix인데도 내용 해시가
달라져 두 파일이 생겼다. 0.1.2는 파일명을 6 B 키로 고정한다. 같은 키의 캡처가
suffix 호환이면 더 긴 머리를 가진 것 하나만 유지하고, 실제 바이트가 서로 다른
경우에만 `key_collision` 변형 파일을 보존한다. v012 로그/폴더는 0개에서 시작한다.

2026-08-25 00:25 재시작 후 확인:

- v011 START 6 / END 6 — 미종료 이벤트 0
- 새 ADPCM BIN 2개
- 예시 `ADPCM_00306B_A000_0E`의 key hex `6B 30 00 00 A0 0E` 정상
- 미수집 대사 로그 1줄(헤더만) — 현재 일본어 잔존 0건

위 v011 세션들은 키 및 중복 시험용 예비 플레이로 보존만 한다. 실제 완주 기준은
0.1.2를 로드하고 새로 시작해 생성되는 v012의 첫 세션 prefix다.

## 스튜디오

`snatcher_tool/SnatcherTranslationStudio.exe`에 음성 자막과 CD-DA 자막 검색을
추가했다. 음성은 키·파일·화자·일본어·상태·메모, CD-DA는 클립·트랙·일본어와
한국어 자막 조각까지 검색한다. 여러 단어는 AND, `Esc`는 검색 초기화다.

## 이어서 할 일

그대로 엔딩까지 진행한다. 가능하면 Lua 창의 Stop으로 종료해 마지막 이벤트를
닫는다. 수집 중에는 v010 옛 로그/BIN과 v011 새 로그를 섞거나 이름을 바꾸지 않는다.
완주 뒤 v011 START/END 전수 대조, BIN 길이 대조, 일본어 잔존 로그 병합, 범용 자막
selector 팩 생성을 순서대로 수행한다. 현재 native 자막 표시는 접수처 첫 음성
E6800_0E 고정 POC이며, v011 키 수집이 범용화의 입력이다.
