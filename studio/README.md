# Snatcher 한국어 패치 스튜디오

스내처 PCE-CD 한국어 패치 전용 번역·검수 도구입니다.

## 편집 기능

- `snatcher_ko_master.tsv` 일본어/한국어/키 검색
- 검색 결과에서 Enter·더블클릭·`전체 목록에서 위치`로 원본 목록 위치 복귀
- 검색 입력 디바운스와 감사/중복 분석 캐시로 대용량 번역표 탐색 속도 개선
- `source_refs` 기반 장면 필터
- 한국어 입력 중 18칸 자동 검사(전용 공백은 0.5칸)
- `BR`, `PAGE`, `END`, `{EMPTY}` 버튼 입력
- 검토 `O`와 `예외처리` 표시
- 동일 일본어에 서로 다른 번역이 붙은 항목 탐지
- 같은 `text_key`의 앞뒤 행 문맥 표시
- 화자명과 UI 번역 편집
- UI 항목별 검토 `O` 기록
- 저장 전 기존 UTF-16 TSV 자동 백업

## 플레이 감사

1. Mesen에서 다른 Lua를 중지합니다.
2. `C:\snatcher\snatcher_tool\mesen\runtime_text_audit.lua`를 실행합니다.
3. Power Cycle 후 평소처럼 플레이합니다.
4. 스튜디오의 `플레이 감사 · 누락 수집` 탭에서 실제 검수 빌드를 고릅니다.
5. `실시간 감시 시작`을 누릅니다.

분류 기준:

- `HIT`: 정상 한국어 치환
- `LOOKUP_FAIL`: 빌드에 정확한 레코드가 있는데 일본어가 남음
- `ROUTE_FAIL`: 원문은 있으나 다른 상태에만 등록됨
- `MASTER_ONLY`: MASTER에는 있으나 검수 빌드에서 제외됨
- `NEAR`: 조합 대사가 기존 원문과 미세하게 다름
- `MISS`: MASTER에 없는 실제 런타임 대사

`번역 큐 내보내기`는 `MASTER_ONLY/NEAR/MISS`만 UTF-16 TSV로 저장합니다.
로그에는 출력 순서·프레임·장면이 남으므로 이후 장면별 프리페치 묶음을 만드는 자료로도 사용합니다.

## 파일 위치

- 실행 파일: `C:\snatcher\tools\snatcher_translation_studio\release\SnatcherTranslationStudio.exe`
- 백업: `C:\snatcher\translation_history\studio_backups`
- 원시 플레이 로그: `C:\snatcher\dump\runtime_text_audit_raw.tsv`
- 분석 보고서: `C:\snatcher\dump\runtime_text_audit_report.tsv`
