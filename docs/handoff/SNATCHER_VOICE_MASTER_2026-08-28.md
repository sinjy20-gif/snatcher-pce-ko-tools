# SNATCHER 음성 최종 마스터 인계 — 2026-08-28

## 결론

- `voice_key_events_raw_v012.tsv`의 ADPCM 고유 열쇠는 **1055개**다.
- 이전 마스터 990개에 오늘 추가 수집분 **65개**를 합쳤다.
- 모든 열쇠에 실제 음원 파일이 연결되어 있다. 누락 0, 중복 열쇠 0,
  중복 대표 클립 0이다.
- 추가 65개만 faster-whisper로 처리했다. 61개에 초벌 일본어 전사가
  생겼고 4개는 무음/비언어 판정으로 빈칸이다.
- 전체 초벌 전사는 1037개, 빈칸은 18개다.
- Studio용 이벤트 마스터도 1055행으로 다시 만들었으며 `voice_keys.tsv`의
  최신 `jp_text`를 `jp_whisper`에 직접 연결한다.
- 기존 990개 열쇠의 사람이 채운 값 손실 0, 기존 자막 118행 손실 0이다.

## 정본 파일

- `snatcher_tool/translation/voice_keys.tsv`
  - 1055행, 고유 열쇠 1055, 고유 대표 음원 1055
- `snatcher_tool/translation/voice_events.tsv`
  - Studio용 1055행, 열쇠/음원/전사 불일치 0
- `snatcher_tool/logs/voice_transcript.tsv`
  - 전사가 있는 1037행, `voice_keys.tsv`와 불일치 0
- `snatcher_tool/translation/voice_subtitles_keyed.tsv`
  - 열쇠 기반 자막 118행 / 56열쇠
- `snatcher_tool/translation/voice_subtitles.tsv`
  - Studio용 자막 118행
- 원음 폴더: `snatcher_tool/logs/voice_clips_v012_fresh`
  - 전체 파일 1190개, 마스터가 참조한 음원 누락 0

## 추가 65개 Whisper 결과

- 실행 로그: `dump/transcribe_voice_keys_new65_20260828_183228.log`
- 오류 로그: `dump/transcribe_voice_keys_new65_20260828_183228.err.log` (0바이트)
- 필터 기준 이전 마스터:
  `snatcher_tool/translation/voice_keys.tsv.bak_20260828_182639`
- 실행 시간: 9.4분
- 전사 성공 61, 빈칸 4

빈칸 열쇠:

- `ADPCM_00934B_2000_0E`
- `ADPCM_009355_5000_0E` — 저음량 779
- `ADPCM_009365_8000_0E`
- `ADPCM_009388_9800_0E`

`ADPCM_009375_8000_0E`의 `<원문 14자>`는 저음량 290의
정형구 환청 의심으로 표시했다. 초벌 전사는 자동 수정하지 않고 원음 대조 대상으로
보존했다.

## 도구 변경

- `tools/transcribe_voice_keys.py`
  - `--only-new-from PATH`를 추가해 이전 990개를 건드리지 않고 새 65개만
    처리할 수 있게 했다.
- `tools/build_voice_keys.py`
  - `--studio` 내보내기에서 `voice_keys.jp_text`를 우선 사용하고, 비어 있을
    때만 이전 `voice_events.jp_whisper`를 승계하도록 고쳤다.

최종 생성 명령:

```powershell
python tools/build_voice_keys.py --studio
```

## SHA-256

```text
26ED5BF21D0D4E936163C7D440837A5A8CD764FC6316B34087971A6A9228F924  voice_keys.tsv
66E600E6901683BC2F696557523E691EFAE288A541399B970191220B32979F09  voice_events.tsv
132BC282E858E2E31BED0EC76BCBCF57B5202D4E7C3D214C57FD06ED76A99327  voice_transcript.tsv
E91A59637F9BB5C111B0AC7F2696C764EA8F5D5E495935D61E8F8410785002D5  voice_subtitles_keyed.tsv
4CFF2BD7D4075D1D1852F84D8835711E70D9E3B53EE9DC8DE0694D52A74337B3  voice_subtitles.tsv
```

## 다음 작업

- 초벌 일본어 전사를 원음과 대조해 고유명사와 짧은 감탄사를 교정한다.
- 아직 번역이 붙은 열쇠는 56/1055이므로, 전사 교정 뒤 한국어 자막을 늘린다.
- 이번 작업은 음성 마스터/Studio 연결만 갱신했다. 자막 팩이나 디스크는 다시
  빌드하지 않았다.

