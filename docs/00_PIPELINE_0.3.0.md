# Snatcher 한국어 패치 — 0.3.0 동결 파이프라인

확정 2026-08-13. **이 문서가 유일하게 유효한 빌드 절차다.**
이전 문서(`SNATCHER_KO_HANDOFF_2026-08-12/docs/15_BUILD_PIPELINE_FINAL`)는
`ac_0.1.14` 기준이고, 여기서 대체됐다.

```
정식 버전   0.3.0
진입점      extraction\patch\static\build_snatcher_ko_0_3_0.py
필수        Arcade CD-ROM² 지원 에뮬레이터 (Mesen2 / Beetle PCE 확인됨)
권장        CD 배속 8x
```

---

## 1. 버전 번호에 대해

두 갈래로 돌던 번호를 하나로 합쳤다.

```
UI 0.1.9 ~ UI 0.4.1     초기 UI 라벨 시도. 대부분 폐기
0.3.0-uitest            UI 렌더 경로 증명. ★ 엔진의 기준
ac_0.1.1 ~ ac_0.1.18    그 엔진 위의 Arcade Card 백킹스토어 개발 시리즈
ac_0.1.14               그 시리즈의 마지막 성공본 = 현재 출하 디스크
                          ↓
0.3.0                   위 조합에 붙인 정식 번호. AC 시리즈 번호는 은퇴
```

`0.3.0` 은 **엔진 0.3.0-uitest + 레코드 포맷 ac_0.1.14** 를 뜻한다.
`build\patch\ac_0.1.14\` 디스크는 개명하지 않고 그대로 둔다 — 검증 로그의
SHA-256 이 그 파일명으로 기록돼 있다. 검토가 끝나고 다음 빌드를 돌리면
`build\patch\0.3.0\` 이 나온다.

⚠ **번호가 크다고 최신이 아니다.** `ac_0.1.18` 이 최대 번호였지만 폐기였다.
이 함정을 없애려고 번호를 통합한 것이다.

---

## 2. 정식 입력 — 이것만 본다

```
snatcher_tool\translation\snatcher_ko_master.tsv        BODY 마스터
snatcher_tool\translation\ui_text.tsv                   UI 라벨
snatcher_tool\translation\speaker_name_standard.tsv     화자명
snatcher_tool\translation\master_conflict_exclusions.tsv 충돌 제외 기록 (자동 생성)
```

편집은 `snatcher_tool\SnatcherTranslationStudio.exe` 로만 한다.

**다른 번역 자료는 확인하지 않는다.** 과거 마스터·후보·백업은 전부
`_archive\translation_legacy\` 로 격리했고, 옮기기 전에 전수 대조해서
**고유 번역 0건**임을 확인했다. 근거는 그 폴더의 `README.md` 에 있다.

> Studio 를 열어둔 채 외부에서 마스터를 고치면 Studio 저장 시 예전 검토열이
> 되살아난다. 외부 수정 전 Studio 를 닫을 것.

### master_conflict_exclusions.tsv 는 번역 자료가 아니다

런타임 trie 는 **일본어 원문 바이트**를 키로 쓴다. 같은 `jp_text` 에 다른
`ko_text` 가 붙으면 게임이 구분할 수 없다. 정책은 임의 통일이 아니라 검토 제외이고,
이 파일이 그 집행 기록이다 (현재 123행, 전부 `O` → 빈칸).
`extraction\translation\exclude_reported_master_conflicts.py` 가 만든다.
**3단계가 산출물로 복사하므로 없으면 빌드가 마지막에 죽는다.**

---

## 3. 포함 규칙 — 검토 O 가 유일한 기준

```
BODY   첫 번째 이름 없는 검토열이 O 인 행
       예외처리 = 문맥 의존 continuation. 검토된 앞줄이 있어야 포함
UI     review 열이 O 인 행          <- 2026-08-13 변경
공통   ko_text 존재나 status 만으로는 절대 포함하지 않는다
       status 가 todo 여도 O 면 포함한다
```

### UI 규칙이 왜 바뀌었나

바꾸기 전 빌더는 `status` 를 아예 보지 않았다. 실제 조건은
`ko_text 가 있고 status != skip` 뿐이었다 — 문서에는 `status = final` 이라고
적혀 있었지만 **코드와 문서가 달랐다.**

그 상태로 재빌드했으면 화면 검증이 안 된 `draft` 159행이 그대로 실렸다.
UI 라벨은 칸 수가 고정이라(액션 메뉴 8칸 8자) **"번역 완료"와 "화면에서 안 깨짐"이
별개의 상태**다. 그래서 BODY 와 같은 검토 축으로 통일했다.

```
build_full_overlay_layout.py
  ui_review_column()   이름 없는 열 우선, 없으면 review 열
  is_ui_reviewed()     O 만 통과
  적용 지점 2곳: load_static_records / expected_static_references
```

두 곳을 같이 고쳐야 한다. 한쪽만 고치면 커버리지 검사가 빌드를 죽인다.

---

## 4. 빌드

```bash
python C:\snatcher\extraction\patch\static\build_snatcher_ko_0_3_0.py
```

```
--check     무엇이 실릴지만 보고하고 종료. 빌드 안 함
--stage3    3단계만. ac_0.1.11-source 중간물을 재사용
(무인자)     1~3단계 전부
```

마스터를 고쳤으면 전체를 돌린다. 1단계가 슬롯 배정을 다시 하므로 2·3단계가 따라야 한다.
3단계 로직만 고쳤으면 `--stage3` 이면 된다.

### 단계별로 하는 일

```
1단계  마스터 -> SRT4 704B 레코드
       build_direct_overlay_patch_ui.py --version ac_0.1.11-source --review-only --force
       산출: build\patch\ac_0.1.11-source\  (중간물이지 배포본이 아니다)

2단계  sparse 32MB 슬롯 이미지 -> 레코드 연속 이미지
       build_ac_backing_store.py
       내용은 안 바꾼다

3단계  compact 128B + 아틀라스 + AC 팩 + 최종 디스크
       build_ac_dynamic_0_1_14.py  (0.3.0 으로 리타깃)
       704B 레코드의 608B 로컬 글리프 중복 제거
         -> 128B compact + 전역 아틀라스 (717 비트맵, 22,944 B)
       빌드 중 compact -> 704B 복원을 전량 대조. 하나라도 틀리면 예외로 죽는다
```

### 링크 방식 (2026-08-13 강화)

빌드는 **수정하지 않는 트랙 21개를 하드링크**한다. 실제 디스크 비용은
폴더당 600MB 가 아니라 **약 200MB** (Track 02 + Track 24 만 실체 파일).

```
Track 02   3섹터 패치           실체 파일  80 MB
Track 24   원본 + AC 이미지 추가  실체 파일 119 MB
나머지 21개 트랙                 하드링크   0 MB
```

체인은 `rom(japan)` → `ac_0.1.11-source` → 산출물까지 같은 inode 다.
빌드를 지워도 원본 ROM 은 안전하다.

전에는 링크 실패 시 **조용히 복사**해서 폴더가 600MB 로 불어났다. 지금은 예외로
죽는다. 다른 볼륨에 산출해야 하면 `SNATCHER_ALLOW_TRACK_COPY=1` 을 준다.

---

## 5. 지금 무엇이 실리나

```
BODY   검토 O   2,227행 (예외처리 10)
UI     번역됨     221 / 992
       검토 O       0        <- 지금 빌드하면 UI 라벨이 0개 실린다
```

**UI 검토열이 비어 있는 것은 버그가 아니라 대기 상태다.** Studio UI 탭에서 화면
확인한 라벨에 `O` 를 찍으면 다음 빌드부터 들어간다. `--check` 가 이걸 경고한다.

출하 중인 `ac_0.1.14` 는 규칙 변경 전에 만들어졌고 UI 레코드 59개를 갖고 있다.

---

## 6. 검증 도구

```
lua\UI 0.1.70.lua              AC RAM 생존 / 포트 접근
lua\UI 0.1.72.lua              CD 적재 계측 ($20F8).  3단계가 산출물에 복사한다
lua\UI 0.1.73.lua              AC 적재 계측 (뱅크 $40)
lua\UI 0.1.74.lua              AC 포트 쓰기 POC 판독
build\patch\ac_0.1.14\ac_0114_verify.txt   디스크 역검증 로그
```

**새 Lua 는 `C:\snatcher\lua\` 에만 만든다.** `restart kit\tools\mesen\` 은 폐지됐다.

---

## 7. 하지 말아야 할 것

```
새 BODY/UI 렌더러나 UI 전용 폰트·번역 시스템을 만들지 말 것
  기준 엔진은 0.3.0-uitest 다.
  $66E5 / $5E40 / $7F50 / $5B80-$5E3F 704B 캐시를 다시 설계하지 않는다

CHUNK_BYTES 를 8 KiB 초과로 올리지 말 것
  BIOS 목적지 종류 4 는 뱅크를 MPR4(8KiB 창)에 매핑한다. 더 큰 청크는 뱅크를
  $40 -> $41 로 넘기는데 그때 AC 자동증분 포인터를 못 따라간다

기존 훅으로 로딩을 앞당기려 하지 말 것
  $66E5 는 대사창이 살아있을 때만 발동한다. 챕터1 오프닝은 그래픽이라 훅이 없다
  초기화는 프레임 3330(약 55초, 접수처)에 일어난다. 그보다 이른 기회가 없다

제자리 치환 방향 금지 (2026-08-10 폐기)
UI+BODY 동시 상주 오버레이 금지 (325B 부족 + $5E20 삼중 역할로 물리적 불가)
BODY 와 UI 데이터를 별도 AC 아키텍처로 분리하지 말 것
runtime 을 독립 교체팩으로 만들지 말 것
runtime ID 를 장면 ID 로 개명하지 말 것
resident 목적지를 유효 바이트만으로 연속 배치하지 말 것 (섹터 extent 정렬 필수)
검토 O 없는 번역을 자동 포함하지 말 것
ac_0.1.14 / ac_0.1.11-source 를 덮어쓰거나 지우지 말 것
```

폐기 빌드 전량과 사유는 `_archive\build_records\DELETED_BUILDS_2026-08-13.md` 에 있다.

---

## 8. 비용 모델 (외워둘 것)

```
틀림   시간 = 호출수 x 188ms + 바이트/150KB/s
맞음   시간 = 바이트 / 34 KB/s        (호출 수는 거의 무관)
```

실측 34 KB/s 는 1x CD 이론치(150 KB/s)의 1/4.4 다. **지연은 전부 CD 탓이고
배속이 그대로 나눗셈으로 들어간다.** 그래서 성능 문제는 8배속으로 종결됐고,
희소 디렉터리 최적화는 불필요해졌다.

```
ac_0.1.14 첫 대사 5.28초 (배속 없음)
이후 장면 전환      0.04 ~ 0.97초
8배속               로딩 체감 소멸 (사용자 실측, 폐공장까지 확인)
```

---

## 9. 남은 일 — 기술이 아니라 데이터다

```
1. BODY 마스터    검토 O 2,227행 / 마스터 13,607행
2. UI 라벨        검토 O 0행 / 번역 221 / 전체 992
3. 자막 렌더러    저작 도구 완성, 런타임 미착수
                  남은 미지수는 프레임 단위 실행 지점
                  (SNATCHER_KO_HANDOFF_2026-08-12/docs/14 §3.1)
```

렌더 경로·글리프 공급·캐시 복원은 전부 검증 완료다. 번역과 검토만 남았다.

### 14,000줄에 도달하면 손볼 두 가지 (지금은 아님)

```
팩 개수 상한 16개 (현재 11개)
  메타데이터가 AC $10080-$100FF 128B 에 있고 팩당 8B. 장면 ~94개에서 초과
  처방: 메타데이터를 AC 여유 공간($18000 등)으로 이전

shared 팩이 상주라서 같이 커진다
  219 -> 약 2,900 레코드 = 371 KB (1x 10.7초 / 8x 1.3초)
  처방: 상주에서 빼고 각 장면팩에 복제. 128B 라 AC 용량엔 부담 없다
```

AC 2 MB 중 현재 약 230 KB 만 쓴다. 자리는 넉넉하다.
