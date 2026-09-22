# SNATCHER 작업 인계 — 2026-08-21 00시

## 1. 오늘 수집분 병합 완료

현역 마스터: `snatcher_tool/translation/snatcher_ko_master.tsv`

- 6,075행 / 3,725페이지
- 번역 5,052행
- 검토 O 4,078행
- 오늘 로그에서 새 페이지 201개 추가
- 수집 창 12,397건, 고유 창 3,725개
- 기존 번역 5,044행 전수 승계, 유실 0행
- 페이지 최대 3행, 구조 오류 0, 누락/분할 꼬리행 0

검증 명령:

`python tools/validate_runtime_window_coverage.py`

백업:

`snatcher_tool/backups/snatcher_ko_master_before_runtime_merge_20260821_000754.tsv`

병합 후보와 보고서:

- `dump/master_by_window_20260821_000740.tsv`
- `dump/master_by_window_20260821_000740_report.tsv` — 유실 0건

## 2. Studio 수집 정책

`snatcher_tool/studio_source/MainForm.cs`의 `대사 포함` 버튼을
`대사 포함 (비활성)`으로 바꾸고 `Enabled=false` 처리했다. 런타임 로그가 마스터의
권위 있는 페이지 골격이며 Studio에서 감사 결과를 임의 편입하지 않는다.

새 Studio는 `snatcher_tool/studio_source/portable_release/`에 빌드됐다. 작업 종료 시점에
기존 Studio가 실행 중이라 현역 EXE 교체는 Windows 파일 잠금으로 실패했다. 압축본에는
새 EXE를 넣었으며, 로컬 현역 교체는 Studio를 닫은 뒤 다음처럼 하면 된다.

`Copy-Item snatcher_tool/studio_source/portable_release/SnatcherTranslationStudio.exe snatcher_tool/SnatcherTranslationStudio.exe`

## 3. 마스터/빌더 기준

- 런타임 `(session, record_seq)` 창을 권위 있는 골격으로 사용
- 같은 페이지 ID의 본문은 최대 3행
- 네 번째 행은 새 페이지 ID
- 마지막 행만 END, 앞 행은 CONT
- 수집된 꼬리행 누락이나 페이지 분할이 하나라도 있으면 빌드 중단
- `build_snatcher_ko_0_4_5_1.py` 입력 검사에 커버리지 검증 연결됨
- Gaudi 사전 R04341–R04572: 669행 번역 완료, 14칸 초과 0
- 새 글리프 `랄략얽` 때문에 최종 BIOS 슬롯맵/폰트 재빌드 필요

## 4. 자막 POC

완료:

- `tools/compile_voice_subtitles.py`
- `build/subtitles/subtitle_runtime.tsv/json`
- Studio 자막 2건 컴파일: ADPCM 1, CDDA 1
- `lua/SUBTITLE_OVERLAY_0.1.3.lua`: ADPCM 에뮬레이터 표시 POC
- `lua/PROBE_SUBTITLE_BORROW_SHADOW_0.1.0.lua`: 임시 RAM 대여 shadow 시험
- 계약: `docs/SUBTITLE_POC_CONTRACT_2026-08-20.md`

다음 시험:

1. Mesen에서 `PROBE_SUBTITLE_BORROW_SHADOW_0.1.0.lua` 실행
2. “금일부로 JUNKER로 임명된 길리언 시드다.” 음성 통과
3. `dump/probe_subtitle_borrow_shadow_0_1_0.tsv` 확인
4. `writes=0`, `execs=0`, `diff=0`이면 active RAM 대피/IRQ 엔진 설치 POC로 진행

중요 주소:

- AD_PLAY `$E03C->$F5C6`
- AD_STAT `$E045->$F6DB`
- 대여 후보 `$5B80-$5FFF`, 1,152바이트
- AC 자막 예약 `$1C0000-$1FFFFF`, 256KB
- CDDA 오프닝: CD_PLAY `$E012`, 호출자 `$60E4`; CD_SUBQ 호출자 `$6119`

구형 `tools/build_subtitle_poc.py`의 `$5C40-$5E1F` 상주 방식은 VM 스택과 겹쳐
폐기됐으며 실행도 차단했다. `SNATCHER_SUBS_POC`도 안전 검증 전까지 차단 상태다.

## 5. 다음 시작 순서

1. Studio가 닫혔는지 확인하고 새 EXE 교체
2. shadow 자막 POC 실측
3. 결과 PASS 시 active 왕복 엔진 작성
4. 대사 검토 완료 후 `voice_events.tsv`의 대사부터 자막 작성
5. 최종 빌드 직전에 BIOS 슬롯맵/폰트, 오버레이 자산, 정적 패치를 전부 재빌드

## 6. 00:20 자막 active POC 성공

`lua/POC_SUBTITLE_ACTIVE_0.1.0.lua`로 길리언 음성 `E6800_0E`를 실측했다.

- `$5B80-$5FFF` 1,152바이트를 AC `$1C0000`으로 대피
- 대여 RAM을 실제로 덮고 IRQ1 벡터 `$2202`를 `$5B80` 체인 스텁으로 교체
- 기존 IRQ1 `$40A4`로 199회 정상 체인
- 게임의 예상 밖 RAM 쓰기 0, 예상 밖 실행 0
- 종료 후 RAM/IRQ 복원 차이 0
- 같은 음성 구간에 16x16 갈무리 한글 자막 실제 표시 성공

표시 가독성은 다음 판에서 2px 외곽선, 아래 그림자, 반투명 검정 띠로 개선한다.
현재 표시는 Lua 픽셀 렌더러이며 다음 구현 단계는 동일한 데이터를 HuC6280/VDC
스프라이트 렌더러로 옮기는 것이다.

이번 인계 압축에는 현재 게임 빌드/패치 이미지, Mesen, ROM, 대형 백업 폴더를 넣지
않는다. 소스, Studio, 현역 번역표, 오늘 수집 원시 로그와 인계 문서만 포함한다.
