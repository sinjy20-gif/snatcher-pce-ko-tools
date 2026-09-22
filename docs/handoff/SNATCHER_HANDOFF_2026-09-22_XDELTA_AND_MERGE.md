# SNATCHER 2026-09-22 인계서 — xdelta 배포 전환 · 환경 B 병합

작성 2026-09-22 낮

## 0. 오늘 한 일 요약

1. `SNATCHER_HANDOFF_20260922_ENV_B.zip`(환경 B, 0.7.14→0.7.26) 을 홈에 **무손실
   병합**했다. 홈은 9/14 이후 독립 편집이 없어 단순 병합이었다.
2. 배포 표준을 **KOPATCH1(Python 적용기) → xdelta(VCDIFF)** 로 바꿨다. "패치
   적용이 어렵다"는 후기가 이유. `0.7.26`·`0.7.24` 둘 다 새 형식으로 다시 쌌다.

세부는 메모리 [[snatcher_20260922_company_merge]] · [[snatcher_xdelta_distribution]]
에 있다. 이 문서는 다음 세션이 바로 이어받을 수 있는 요약이다.

## 1. 배포 산출물 — 실물

```
dist/snatcher-ko-0.7.26-xdelta.zip   3.7 MB   최신 테스트판
dist/snatcher-ko-0.7.24-xdelta.zip   3.7 MB   안정 비교판
```

각 zip: `README.md`(적용법 2가지) · `apply.bat`(무설치, xdelta3 동봉) · `patch/*.xdelta`
· `patch/index.json` · `xdelta3/`(exe 2개 + Apache-2.0 LICENSE) · `[KO].cue`.

**검증 완료:** 생성 직후 되풀기 자체 검산(도구 내장) + `apply.bat` 을 실제 원본
BIOS/Track02/Track24 에 돌려 최종 SHA-256 이 `index.json` 의 `dst_sha256` 과
전부 일치. **에뮬레이터로 실제 플레이해서 확인하지는 않았다** — 파일 무결성만.

대상은 **BIOS · Track02 · Track24** 세 개다(Track04 아님). 사용자 지시가
"트랙 4" 였는데 기존 배포·환경 B 인계 전부 Track24 기준이라 오기로 보고 진행했다 —
**다음 세션에서 이 판단이 맞았는지 한 번 확인할 것.**

## 2. 반복 생성 도구

```
tools/make_xdelta_patch.py <판>
```

기본은 `build/patch/<판>/` 의 결과물을 원본과 비교한다. `--bios-dst` 등으로
다른 위치도 가능(오늘 이걸로 환경 B kopatch 를 원본에 되풀어 재현한 파일을 썼다).
소스 윈도우 256 MiB · `-9 -S lzma`. 생성마다 되풀기 검산까지 자동으로 한다.

`tools/vendor/xdelta3/xdelta3.exe` — 공식 배포 바이너리(v3.2.0, Apache-2.0),
GitHub Releases 자산 해시 대조 후 받았다. `pip install xdelta3` 는 Windows 에서
MSVC 가 없어 안 된다.

다음 판(0.7.27+)을 배포할 때: `build/patch/<판>/` 을 만든 뒤 위 명령 한 줄, 그 뒤
`dist/snatcher-ko-0.7.26-xdelta/` 의 README·apply.bat·xdelta3 폴더·cue 를 복사해
버전 문자열만 바꾸면 된다. **apply.bat 은 반드시 CRLF 로 저장할 것** — LF 면
cmd.exe 파서가 깨진다(2026-09-22 에 여기서 한참 헤맸다, 메모리 참고).

## 3. 환경 B가 9/14~18 에 이어간 것 (0.7.14 → 0.7.26)

- 가우디 자판이 **45→48칸**으로 바뀌었다: 인명 검색 16개 + 퀴즈 + **화상전화
  숫자판**(신규) 추가. 분할 슬롯이 `$243-$245`(옛) → `$27E/$27F/$280`(새)로
  이동했다 — 옛 0.7.15 판을 다시 만질 땐 `LEGACY_SPLIT_SLOTS` 를 봐야 한다.
- 타이틀 메뉴·오프닝 자막(DNFBitBitv2 폰트) 한글화, Route C 화면 치환.
- CD-DA/ADPCM 단일소유 오버레이, CPU 캐시 반납 범위 조정, ROM 상주 렌더러.
- 화면 위쪽 한 프레임 깜빡임: 최악노출 41→17줄, 큰 사건 9→**0건**.

## 4. 0.7.26 미검증 항목 (환경 B 인계서 원문 그대로 옮김)

1. CPU 캐시 꼬리 2바이트(`$5E1D`·`$5E1E`) 미복원 — 실험적. 한 장면만 확인.
2. 전원 투입 시 자막 엔진 오초기화, 이론상 **256회 중 1회꼴**.
3. 남은 깜빡임 7~17줄 18건 · 1~2줄 19건.
4. 자막 폭 192px 한도 — 기하적 한계.
5. 가우디 사전 일본어 4줄, 빈 줄 4개, 드문 미수집 가능성.
6. 엔딩 그래픽 미한글화, 가우디 `결정` 글자 셀 살짝 넘침.

## 5. 병합 세부 — 무엇이 어디로

`SOURCE_SNAPSHOT` → 같은 이름으로 robocopy(`tools/lua/docs/dump/extraction/qa/SUB/build`,
삭제 없음, 누락 0 확인) · `TRANSLATION_STUDIO` → `snatcher_tool`(번역 정본 최종
해시 `380A39D1A0CEAB9A247E93D1C123CBB79F4253B7DB4D4EFEF64A92937D325249` 확인,
병합 전 백업 `snatcher_tool/translation/backups/20260922_103208_*`) ·
`BUILD_METADATA/0.7.26` → `build/patch/0.7.26/`(메타데이터만) · `EVIDENCE` →
`dump/` · `HISTORY` → `docs/handoff/HISTORY_from_20260922_company/` · `TEST_STATE`
최신 → Mesen 라이브 슬롯(**교체 전 백업**: `*.bak_20260922_103334_*`) · 9/14
가우디 과거 기준점 → `docs/handoff/TEST_STATE_reference/`.

압축 해제한 448 MB 폴더는 전부 병합 확인 후 삭제했다. 원본 zip 은 루트에 남아
있고, 핵심 문서 6개는 `archive/imported_handoffs/20260922_company/` 에 따로
보관했다(기존 R2/R3 관례와 동일).

## 6. 다음

1. **0.7.26 을 실제로 에뮬레이터에서 플레이해서 확인** — 오늘은 파일 무결성만
   확인했고 QA 는 안 했다.
2. xdelta zip 을 실제 배포 채널(포럼 등)에 올리기 전에 **직접 한 번 더 적용해서
   확인** — 특히 `apply.bat` 을 다른 PC/다른 드라이브 경로에서도 테스트.
3. "트랙 4" 지시가 정말 트랙24 를 뜻한 게 맞는지 확인.
4. 0.7.26 미검증 5개 항목(§4) 우선순위대로 실기 검증.
5. `snatcher_tool/studio_source` 의 466 MB 빌드 산출물 정리는 아직 안 했다
   (요청받지 않아 손대지 않음).

별도 지시 전까지 배포 파일 이름의 판 번호는 위 상태(0.7.26/0.7.24)를 유지한다.
