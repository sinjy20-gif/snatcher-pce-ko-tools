# 2026-09-11 저녁 인계 — CD-DA 트랙 4 시험 중지 / 마스터 보호

## 지금 멈춘 상태

- 오늘은 더 빌드하거나 테스트하지 않는다.
- `snatcher_tool/translation/cdda_subtitles.tsv`는 **마스터**다. 직접 수정 금지.
- 트랙 4 그래픽 충돌을 보려고 이 파일의 2·4번 줄을 13칸 시험값으로 바꿨던 것은 잘못된 절차였다. 두 줄은 복구했다.
  - 04-02: `조금만 늦었으면 저승행이었어.`
  - 04-04: `나? 랜덤 하질. 바운티 헌터다.`
- 복구 뒤 두 행은 `cdda_subtitles_before_20260911_track4_14cell_test.tsv`의 해당 행과 일치한다. 파일 전체는 사용자가 그 뒤 저장한 변경이 있을 수 있으므로 통째로 과거 백업으로 되돌리지 않았다.

## 13칸에 관해 바로잡을 것

- **트랙 4 전체 13칸 제한은 아니다.** 그렇게 적용하면 안 된다.
- 화면에서 확인한 `해마다 그 수가 줄고 있습니다.`(04-08)은 공백·마침표 포함 **17칸**이다. 이 줄이 보인다는 사실 자체가 전역 13칸 제한이 아니라는 증거다.
- `build/patch/0.7.7-track4-14cell-test`와 `build/patch/0.7.8-track4-13cell-test`는 시험 산출물이다. 특히 0.7.8에는 당시 04-02/04-04의 13칸 시험값이 구워져 있다. 배포판/기준판으로 쓰지 말 것.
- 다음 시험은 마스터를 복사한 별도 TSV를 입력으로 빌드하게 만든 뒤에만 한다. 원본 경로를 바꾸거나 덮어쓰지 않는다.

## 아직 해결되지 않은 것

- 게임 화면의 자막이 노랗게 보이는 문제는 **미해결**이다. 팔레트 15의 흰색·검정 초기화가 게임의 후속 팔레트 기입에 덮일 가능성을 확인했을 뿐, 코드나 마스터에는 아직 수정하지 않았다.
- 다음에는 별도 시험 디스크에서만 팔레트 재기입을 시험한다. 우선순위는 마스터 분리 → 시험판 생성 → Mesen 확인이다.

## 오늘 병합한 인계본

`SNATCHER_HANDOFF_20260911_075_FINAL`의 규칙대로 다음을 병합했다. 삭제 동기화는 하지 않았다.

- `.../project` → `C:\snatcher`
- `.../snatcher_tool` → `C:\snatcher\snatcher_tool`

현행 `SnatcherTranslationStudio.exe`, `studio_source/MainForm.cs`, `ClipPlayer.cs`, `SubtitleTimeline.cs`는 인계본과 SHA-256이 일치한다. 즉 CD-DA 조각 나누기/타임라인 기능이 든 스튜디오가 현재 `C:\snatcher\snatcher_tool`에 있다.

인계 폴더 자체의 재귀 삭제는 실행 환경의 안전 제한으로 차단되어 아직 남아 있다. 병합은 끝났고, 폴더 삭제만 수동으로 하면 된다.

## 별도 반영됨

- `tools/build_cdda_mini_index_all.py`: 트랙 6은 실기 검증 `PROVEN_BASE $3B00`을 계속 쓰게 했다. 구간별 관찰값이 이사를 제안해도 renderer/helper base가 어긋나는 기존 이사 경로는 쓰지 않는다.

## 2026-09-12 원복

- `build/patch/cddafix/0.7.7-cddafix-current-test/`는 혼합 엔진 시험을 중단하고 0.7.7 기준판의 Track24와 manifest로 원복했다.
- 혼합 번들을 넣었던 중간 파일은 `.pre_bundle_patch` 백업으로 남아 있지만, 현재 실행 대상에는 반영되지 않는다.
- 전체 체인은 BIOS 로더가 `275/272`로 초과하여 실패했고, 실패한 중간 산출물은 `build/patch/_FAILED_0.7.7-cddafix-current-built_loader-overflow/`에 보존했다.
- 0.4/0.5 버전 폴더 이동도 취소하여 원래 `build/patch` 바로 아래로 되돌렸다.

## 새 자막 시험판

- `build/patch/cddafix/0.7.7-cddafix-rebuild-test/`에 새 마스터 입력으로 시험판을 만들었다.
- 팩 태그는 `EE20D5D8`, 마스터 TSV SHA-256은 `C374A8281B5DC446EC7C86C8E4C8C876D0A387F49D83C20C45FB977C6B277B12`다.
- BIOS와 기존 CD-DA 렌더러는 기준판 그대로 두고, ADPCM 데이터·CD-DA mini index·트랙 디렉터리만 교체했다.
- 실행 전 시험판이며, Mesen에서 화면·자막·싱크를 확인해야 한다.
