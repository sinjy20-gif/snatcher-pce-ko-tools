# 환경 B 병합 기록 — 2026-09-11 (환경 A 번들 `snatcher_work_bundle_20260910_2332`)

번들: `snatcher_work_bundle_20260910_2332.zip` 1,206,417,132 B · 항목 5,089
인계서: `docs/handoff/SNATCHER_20260910_NIGHT.md` (번들 안에 있었다 · 이제 라이브)

## 1. 압축 해제 검증

zip 5,089 파일 = 디스크 5,089 · **없음 0 · 크기 불일치 0**.

## 2. 안전 판정 — 대조군은 없었지만 결론은 같다

09-09 환경 이동 정리(`ENV_B_CLEANUP_2026-09-09.md`)가 `SNATCHER_ENV_A_20260909.zip` 과
풀린 폴더를 **둘 다 지웠다.** `FILE_MANIFEST.tsv`(파일별 sha256)도 같이 사라져
[[snatcher-bundle-merge-time-window-rule]] 의 대조본 판정을 쓸 수 없었다.

대신 **환경 B 쪽 무작업**을 직접 실측해 같은 보증을 얻었다:

    tools lua docs extraction snatcher_tool build dump 에서
    09-09 17:40 이후 수정된 파일 :  0 개

전수 해시 대조에서도 **live-newer 0 건**. 즉 환경 B 라이브는 09-09 에 환경 A로 보낸
그 상태 그대로고, 번들의 모든 차이는 순수한 환경 A의 하류 작업이다. 덮어도 손실 0.

## 3. TSV 내용 검증 (덮기 전)

[[snatcher-bundle-merge-time-window-rule]] 의 "raw 줄 대조 먼저" 를 따랐다.
줄 포함관계는 상대가 **고치면** 항상 깨지므로 키 단위로 다시 봤다.

    snatcher_ko_master.tsv    16,205 -> 16,259 키   라이브에만 있는 키 0
                              ko_text 전 행 채움 유지
    cdda_subtitles.tsv          765 ->    736 행   사라진 29 행이 **전부 트랙 01**
                              번역 100% 유지 · 번들에만 있는 키 0

트랙 01 제거는 인계서 §1-2 가 말한 그대로다 — **인계서와 실측이 일치한다.**

## 4. 배치 결과

    동일        2,653
    덮음           20      7.3 MB   원본 -> _archive/office_before_home_merge_20260911/
    신규          972    302.8 MB
    아카이브       37      4.9 MB   -> _archive/20260911_home_bundle_unplaced/
    의도적 제외 1,407  1,075.0 MB
    ----------------------------------
    합계        5,089

검증 재대조: **라이브 일치 3,600 · 없음 0 · 불일치 0.**

### 제외한 것과 사유

    tools/emucap/target/ (release/*.exe 제외)  1,395  602 MB
        cargo 빌드 캐시. emucap 자체 .gitignore 가 `/target` 을 뺀다.
        `cargo build --release` 로 재생성. ★ 실행 파일 13 개(40.9 MB)는 올렸다.
    tools/snatcher_translation_studio/            12  442 MB
        publish_runtime_controls · publish_studio_fix · backup_before_fix · release
        전부 08 월 .NET publish 사본. 현행 exe 는 snatcher_tool/ 에 있다.
        [[snatcher-bundle-merge-time-window-rule]] 이 "아카이브도 안 한다" 고 못박은 것.
    build/bios_font/  37 개 -> 아카이브
        08-20 ~ 08-26 BIOS 실험 산출물. 라이브에 안 두는 규칙.
        (같은 폴더의 45 개는 이미 라이브에 동일하게 있었다.)

## 5. ★ 번들이 안 실은 것 — `build/patch/0.7.2`

인계서 §0 이 "지금 올릴 판" 으로 지목한 **`build/patch/0.7.2` 폴더가 번들에 없다.**
환경 B `build/patch/` 최신은 `0.6.4` 다. [[bundle-extract-does-not-cover-live-tree]] 가
말한 **디스크·BIOS 누락**이 이번에도 그대로다.

다만 이번엔 **BIOS 는 왔다** — Mesen 펌웨어 슬롯으로:

    Mesen_2.2.1_Windows/Firmware/[BIOS] Super CD-ROM System (Japan) (v3.0).pce
    09-10 22:44 · sha256 200423906eb024f364333ad0...

없는 것은 CUE 와 Track 02 / Track 24 다. 환경 B에서 다시 구우면 된다 —
빌더·팩·관찰 자료가 전부 올라왔고 기준판도 남아 있다:

```bash
python C:\snatcher\tools\make_subtitle_build.py 0.7.2 --skip-oversize
```

(`make_subtitle_build.py` 는 이번에 9,330 -> 13,183 B 로 갱신됐다. §1-1 의
`[8/8]` 그래픽 제자리 얹기가 들어간 판이다. 기준판 `0.4.6.61-dictionary-key-vram`
과 `EXPERIMENT/0.4.6.61-reviewed-dictionary-unpatched` 둘 다 환경 B에 있다.)

## 6. 인계서가 남긴 것 — 다음 첫 수

    ★ 다음에 이것부터:  글리프 창 줄이기 (선택지 4)
      트랙 5·6 만 칸 수를 줄여 창을 좁힌다. 자리를 옮기는 게 아니라 좁히는 접근이라
      09-10 에 3연패한 것과 성격이 다르고, 코드를 거의 안 건드린다.

    ⚠ PROVEN_BASE 의 5:$7300 · 6:$3B00 을 풀지 말 것.
      빼면 빌더가 새 관찰을 보고 $6300 으로 가서 0.7.4 가 재현된다.
      확인함 — tools/build_cdda_mini_index_all.py:332 에 주석과 함께 박혀 있다.

    관찰 모델(buildOccupancy)의 부호가 실기와 **반대**다. 두 지표(쓰기만 / 참조까지)를
    한 표에 나란히 뽑기 전엔 관찰로 base 를 고르지 말 것. 대조군은 이미 있다
    (트랙 3 = 실기 정상 · 트랙 5 = 실기 깨짐).

## 7. 번들 철거

검증 통과 후 삭제:

    snatcher_work_bundle_20260910_2332.zip     1,206,417,132 B
    snatcher_work_bundle_20260910_2332/        (풀린 폴더 3,158 MB)

되돌릴 것이 있으면 `_archive/office_before_home_merge_20260911/` (덮은 원본 20 개).
