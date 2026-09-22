# 엔딩 「疑い。それは…」 GFX 한글화 인계 — 2026-09-22

## 0. 현재 판정

**미해결. `0.7.27-gfx-ending-g14`는 배포 금지 실험판이다.**

정적으로는 후보 타일/BAT 블록을 한글 데이터로 치환했고 압축 왕복·Track 02
되읽기·Mode 1 EDC/ECC 재계산까지 통과했다. 그러나 소유자가 해당 장면보다 한참
앞선 세이브스테이트로 실제 실행했을 때 일본어 GFX가 그대로 나왔다.

따라서 다음 두 추정은 폐기한다.

- `세이브스테이트에 이미 일본어 VRAM이 들어 있었다` — 한참 전 상태였으므로 근거 없음.
- `완성 VRAM과 동일하게 풀리는 블록을 찾았으니 실제 소스도 확정됐다` — 런타임 반증.

다음 작업은 **실제 장면에서 압축 해제기에 들어오는 소스 P/뱅크를 프로브로 잡는 것**이다.

## 1. 장면과 원문

원문 한 장:

```text
疑い。<원문 9자>
<원문 5자>。
<원문 12자>
<원문 7자>。
今、<원문 10자>
である。
```

그래픽은 한 장이고 게임이 기존 연출로 2줄씩 순차 출력한다. 페이지별 별도
타일/BAT를 만들거나 출력 코드를 바꾸면 안 된다.

현재 한글 문안:

```text
의심은 언제나
투쟁을 낳아 왔다.
진정한 투쟁은
마음속에 있을지도 모른다.
이제 투쟁은
막 시작되었을 뿐이다.
```

## 2. 헌정사와 동일하게 맞춘 규격

`tools/build_gfx_dedication_route_c.py`의 글리프·타일·열 우선 BAT 생성 함수를
그대로 호출한다.

- 폰트: Galmuri14
- 기준선: 15
- 자간: 1 px
- 공백: 5 px
- 정렬: 원본처럼 왼쪽
- 글자 폭: 24칸 = 192 px
- 줄 시작 행: `5, 8, 11, 14, 17, 20`
- 32×32 열 우선 BAT
- 타일 시작: `$200`
- 원본 타일 수: 158장
- 현재 한글: 155장 — 원본 VRAM 범위 안

산출물:

```text
build/gfx/ending_struggle.txt
build/gfx/ending_struggle.routec.tiles.bin
build/gfx/ending_struggle.routec.tiles.pack
build/gfx/ending_struggle.routec.bat.bin
build/gfx/ending_struggle.routec.bat.pack
build/gfx/ending_struggle.routec.png
tools/build_gfx_ending_struggle.py
```

빌드 결과:

```text
타일 4,960 B -> pack 1,205 / 후보 자리 1,491 B · 왕복 일치
BAT  2,048 B -> pack   567 / 후보 자리 1,024 B · 왕복 일치
```

## 3. 캡처 자료

새 완성 화면 캡처:

```text
dump/gfx_20260922_134848_001.vram.bin
dump/gfx_20260922_134848_001.cram.bin
```

같은 장면의 기존 누적 캡처:

```text
dump/gfx_20260911_180451_001.*   앞부분
dump/gfx_20260911_180454_002.*   마지막 2줄
dump/gfx_20260911_180455_003.*   전체 6줄
dump/gfx_20260911_180456_004.*   전체 6줄
dump/gfx_20260911_180457_005.*   전체 6줄
```

모두 캡처 인덱스상 `cdrom.scsi.sector=11473`이다. 이 값은 캡처 순간의 SCSI 상태일
뿐 그래픽 소스 LBA라고 단정하면 안 된다.

## 4. 실패한 후보 블록

완성 VRAM을 정적으로 역검색해서 아래 한 쌍을 찾았다.

```text
타일  논리 $0EB0103 · 헤더 1 B · 자리 1,491 B -> 5,056 B = 158장
BAT   논리 $0E98CF6 · 헤더 2 B (`60 40`) · 자리 1,024 B -> 2,048 B
```

다섯 캡처 모두 같은 후보로 역검색됐다. `patch_gfx_screen.py`에
`ending_struggle` 항목을 추가해 이 둘을 치환했다.

실험판:

```text
build/patch/0.7.27-gfx-ending-struggle   Galmuri11 초기판, 폐기
build/patch/0.7.27-gfx-ending-g14        헌정사 크기판, 런타임 실패
```

`0.7.27-gfx-ending-g14`의 Track 02 해시:

```text
0645BE52508FA30CE2BA154010ACE33B175F1B1B748EA12698A3EA7A2D5947E7
```

후보 블록은 실제로 바뀌고 되읽으면 한글 산출물과 일치한다. 그럼에도 런타임에서
일본어가 나왔으므로, 이 위치가 실제 로딩 소스가 아니거나 다른 매체/사본/경로가
선택되는 것이다. **이 주소를 더 수정하거나 사본을 추측해서 늘리지 말 것.**

## 5. 다음 프로브 — 이것부터

```text
lua/GFX/0.8.4-ending-source-block.lua
```

사용법:

1. 첫 일본어 2줄이 나오기 전에 로드한다.
2. 6줄이 모두 나올 때까지 진행한다.
3. Script 창에서 Stop한다.

산출물:

```text
dump/ending_src_0_8_4_<시각>_hits.tsv
dump/ending_src_0_8_4_<시각>_blk_*.bin
dump/ending_src_0_8_4_<시각>_summary.txt
```

프로브는 `$7061` 루프 자체가 아니라 검증된 세 호출부 `$6FA1/$700E/$7056`를 잡는다.
따라서 한 히트가 압축 블록 하나다. 소스 `P`, record P, bank, `$3F80` 기준 뱅크,
VRAM 목적지와 소스 앞 4 KB를 저장한다. 메모리/VRAM 쓰기는 0이다.

프로브가 끝나면 `blk_*.bin`의 앞부분을 Track 02/24 등에서 바이트 검색해 실제
소스 위치를 확정한다. 계산식으로 LBA를 추정하지 말고, 덤프 바이트 일치로 찾는다.

## 6. 확정 후 구현

실제 타일/BAT 블록이 확정되면:

1. `tools/build_gfx_ending_struggle.py`의 `TILE_AT/TILE_ROOM/BAT_AT/BAT_ROOM`을 수정한다.
2. `tools/patch_gfx_screen.py`의 `ending_struggle` 블록 표도 같은 값으로 수정한다.
3. `0.7.26`을 기준으로 새 후보 폴더를 만든다.
4. 압축 왕복, 블록 앞/뒤 `$FF`, Track 02 되읽기, EDC/ECC를 검증한다.
5. 장면보다 앞선 상태에서 런타임 확인 후에만 `make_subtitle_build.py` 자동 체인을 유지한다.

## 7. 무관한 기존 감사 실패

`check_build_invariants.py 0.7.26` 자체가 Track 24 해시 불일치 1건을 이미 낸다.
`0.7.27-gfx-ending-g14`의 동일 실패는 이번 GFX 변경에서 생긴 것이 아니다. 다만
새 엔딩 GFX가 실제로 나오지 않는 문제와도 관계없으므로 서로 섞지 말 것.
