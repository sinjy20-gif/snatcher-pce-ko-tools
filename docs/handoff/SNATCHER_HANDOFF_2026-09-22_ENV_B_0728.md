# SNATCHER 2026-09-22 환경 B 작업 인계 — 0.7.28 · 엔딩 GFX · 최신 Studio 정본

작성: 2026-09-22 오후  
기준 작업 폴더: `C:\snatcher`

## 0. 가장 먼저 읽을 것

현재 작업판 번호는 소유자 지시대로 **0.7.28**이다. 별도 지시 전에는 0.8.0으로
올리지 않는다.

환경 B에서 생성한 최종 실행판은 `build/patch/0.7.28`이다. 이 인계 ZIP에는 저작권
원본과 완성 Track BIN을 넣지 않았다. 환경 A 프로젝트에 이 ZIP을 **삭제 없이 덮어쓴 뒤**
아래 명령으로 0.7.28을 다시 굽는다.

```powershell
python tools/make_subtitle_build.py 0.7.28 --skip-oversize --adpcm-reuse
python tools/check_build_invariants.py 0.7.28
```

같은 이름의 `build/patch/0.7.28`이 이미 있으면 빌더가 중단한다. 환경 A에 있는 기존
0.7.28은 별도 이름으로 보관한 뒤 실행한다. 번역 정본은 반드시 Studio를 닫고
복사한다.

## 1. 이번 환경 B 작업 결과

### 1.1 Studio 번역 정본

최신 정본과 파생물을 함께 넣었다.

```text
snatcher_tool/translation/snatcher_ko_master.tsv
snatcher_tool/translation/voice_subtitles.tsv
snatcher_tool/translation/cdda_subtitles.tsv
snatcher_tool/translation/voice_subtitles_keyed.tsv   # 빌드 파생물
snatcher_tool/translation/unified_heads_now.tsv       # 최신 진단물
```

핵심 정본 SHA-256:

```text
snatcher_ko_master.tsv  0C87161E49157A8803E30FF2ECEE6A2858D1EF8FB5374EDCB9F91A82D6E5D1F4
voice_subtitles.tsv     FC8D0E13002B367F0AFB08A4CEE59B0647B18014ABC69B19097FA64615FBCDD4
cdda_subtitles.tsv      56D5143C5546A21A53B3C9BFE91AE2CBFC2042643E03E829A18BF7390E861B46
```

Studio 실행 파일과 현재 소스도 ZIP에 포함했다. 환경 A에서 기존 정본을 더 수정했다면
TSV를 통째로 덮지 말고 키 단위로 비교·병합한다.

### 1.2 새로 수집한 대사 R09869

다음 두 줄이 Studio 정본에 들어갔다.

```text
R09869:1  しかし、                         하지만,
R09869:2  <원문 17자>  여기가 제조 공장은 아닌 듯하다…
```

`R09869:2`의 `root_mode`를 `PAGE`로 지정했다. 그렇지 않으면 첫 줄만 치환되고 둘째
줄은 일본어로 남는다.

검증:

```powershell
python tools/locate_dict_screen_lines.py --record R09869
```

두 행 모두 `ROOT`, blocked 0이어야 한다. 환경 B Mesen에서 실제 화면 한글 치환을
확인했고 소유자가 **통과** 판정했다.

### 1.3 엔딩 「의심은 언제나…」 GFX

최종 문안:

```text
의심은 언제나 투쟁을
낳아 왔다.
진정한 투쟁은 마음속에
있을지도 모른다.
이제 투쟁은
막 시작되었을 뿐이다.
```

관련 파일:

```text
tools/build_gfx_ending_struggle.py
tools/patch_gfx_screen.py
tools/make_subtitle_build.py
build/gfx/ending_struggle.txt
build/gfx/ending_struggle.routec.*
dump/gfx_20260922_134848_001.vram.bin
dump/gfx_20260922_134848_001.cram.bin
```

헌정사 GFX와 같은 Galmuri14 규격을 사용한다. 화면은 한 장이고 게임이 팔레트를
바꾸어 2줄씩 보여 준다. 처음에는 BAT 전체가 palette 0이라 여섯 줄이 한꺼번에
나왔다. 현재 빌더는 BAT의 팔레트 비트를 다음처럼 나눈다.

```text
1~2행  palette 0
3~4행  palette 1
5~6행  palette 2
```

최종 산출물:

```text
타일 154장 · 4,928 B -> pack 1,199 B / 자리 1,491 B
BAT  2,048 B -> pack 798 B / 자리 1,024 B
```

한글 GFX 자체가 나오는 것은 확인했다. **팔레트 수정 뒤 실제로 2줄씩 순차 표시되는
최종 장면은 환경 A에서 한 번 더 확인할 것.** 옛 문서
`SNATCHER_ENDING_STRUGGLE_GFX_2026-09-22.md`의 “치환 실패” 판정은 이후 해결 전
상태이므로 이 문서를 우선한다.

### 1.4 0.7.28 최종 빌드

환경 B 실물 SHA-256:

```text
BIOS     EFFD8CE025959070D5AC5A7864B214264907660820EF4782956E2726B9F9EB80
Track02  9E0165D77CA7EA2BE8B47FE12666241D6C6EF74E6865697D5E36A4CB65D86B6B
Track24  A1EFE48CE5C71569EB6C46BD8FD5CD156357C514D637F49A27604666C40C8DBF
```

`check_build_invariants.py 0.7.28` 결과:

```text
통과 11 · 경고 2 · 실패 0
```

경고 둘은 후속 BIOS 패치 때문에 매니페스트의 중간 BIOS 해시가 다른 것과, 도달
불가한 옛 지문 검사 47 B가 남은 것이다.

## 2. 중요 발견 — 타이틀 화면은 아직 미반영

0.7.28 타이틀 메뉴의 일본어가 그대로다. 조사 결과 `make_subtitle_build.py`의
Route C 자동 체인은 헌정/RSS/면책/깁슨/전화/엔딩만 호출하고 아래 둘을 호출하지
않는다.

```text
tools/patch_title_menu_sprite_ko.py
tools/patch_opening_caption_ko.py
```

0.7.26과 0.7.28 Track02를 논리 이미지로 비교하면 차이는 새 엔딩 타일/BAT 두
범위뿐이었다. 따라서 “0.7.26에는 타이틀·오프닝이 들어갔다”는 과거 인계 문구와
달리, 적어도 현재 보존된 0.7.26 실물에도 타이틀 패치가 없었다.

### 환경 A에서 가장 먼저 할 일

타이틀 메뉴에서 일본어 선택지 두 줄이 완전히 뜬 뒤 다음 프로브로 `G`를 한 번
누른다.

```text
lua/GFX/PROBE_GFX_SCREEN_0_2_0.lua
```

생성물은 `dump/gfx_<시각>_001.vram.bin`과 `.cram.bin`이다. 64 KiB 전체 VRAM
덤프가 필요하다. 현재 `patch_title_menu_sprite_ko.py`가 찾는 옛 파일
`dump/title_menu_20260914_235434_vram_full.bin`은 환경 B 폴더와 환경 B 인계 ZIP 어디에도
없다. 기존 조각 덤프만으로는 두 압축 블록 전체를 안전하게 특정할 수 없다.

새 덤프를 얻은 뒤:

1. 타이틀 빌더/패처가 새 전체 VRAM을 입력으로 받게 한다.
2. `patch_title_menu_sprite_ko.py 0.7.28 --write`로 두 블록, 각 2사본을 치환한다.
3. 오프닝은 기존 덤프가 있으므로 `patch_opening_caption_ko.py 0.7.28 --write` 가능하다.
4. 둘을 `make_subtitle_build.py` 자동 체인에 넣고 매니페스트의 허용 Track02 섹터도
   누적한다.
5. Power Cycle 후 타이틀과 오프닝을 확인한다. 옛 세이브스테이트로 판정하지 않는다.

## 3. 자막 그림 밀림 관련 현재 판단

0.7.26에서 ADPCM 시작 때 엔진 복사를 생략하는 `--adpcm-reuse` 경로를 사용했다.
그럼에도 체감 개선이 크지 않아, 소유자 판단대로 한 원인이 아니라 여러 원인의 합일
가능성이 높다. UI 갱신 밀림은 ADPCM 엔진 복사와 별도 문제로 본다. 이번 환경 B
작업에서는 추가 최적화를 하지 않았다.

## 4. 환경 A에서 합치는 순서

1. 환경 A `C:\snatcher`를 별도 백업한다.
2. 이 ZIP의 `PROJECT_OVERLAY`를 프로젝트 루트에 **삭제 없이** 복사한다.
3. 환경 A에서 오늘 이후 TSV를 편집했다면 §1.1 파일은 키 단위 병합한다.
4. `CHECKSUMS_SHA256.txt`로 전송 무결성을 확인한다.
5. 기존 0.7.28 폴더를 보관하고 §0 명령으로 재빌드한다.
6. R09869 화면, 엔딩 2줄 단계 출력, 타이틀/오프닝 순으로 확인한다.

## 5. 배포

아직 0.7.28 xdelta를 만들지 않는다. 타이틀·오프닝 GFX와 엔딩 2줄 단계 출력까지
확인한 다음 배포용 0.8.0을 만든다. 배포물은 BIOS/Track02/Track24 세 개의 xdelta만
내는 기존 방침을 유지한다.

