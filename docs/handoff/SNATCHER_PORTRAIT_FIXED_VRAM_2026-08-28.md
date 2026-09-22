# SNATCHER 초상화 고정 배치 · 자막 빈공간 인계 — 2026-08-28

## 결론

- 초상화는 임의 좌표에 나타나는 구조가 아니라 **왼쪽(L)·가운데(C)·오른쪽(R)
  세 자리 중 하나에 고정 배치**된다.
- 가능한 조합은 `NONE / L / C / R / LC / LR / CR / LCR`이다.
- 특히 사용자가 지적한 것처럼 **가운데를 비우고 L+R만 나오는 경우도 있다.**
- 실측 중 위 조합을 벗어난 예상 밖 배치는 나오지 않았다.
- 화면상 자막은 `Y=122`의 한 줄이고, 초상화 영역은 그 아래쪽이므로 현재
  자막 화면 좌표는 초상화를 직접 덮지 않는다.
- 별개로 자막 패턴을 저장할 VRAM 공통 빈공간을 조사했고,
  **`$1600-$1ABF`를 고정 후보로 채택**했다.
- 이 범위는 19글자에 필요한 `$4C0` word이며, 초상화 8배치 교집합에서
  비어 있었고 장시간 감시에서도 쓰기·BAT 참조·SATB 참조가 모두 0이었다.
- 현재 결정은 **고정 경로 `$1600-$1ABF`로 진행**하는 것이다.
  동적 allocator는 삭제하지 않고 예비안으로 보존한다.
- 자막을 전부 연결한 뒤 처음부터 전수 확인하고, 실제 충돌이 발견될 때만
  allocator를 다시 검토한다.

---

## 1. 혼동하면 안 되는 두 종류의 위치

### 화면 좌표

초상화와 자막이 실제 화면의 어디에 보이는지를 뜻한다.

```text
초상화 자리   L / C / R 고정
자막 한 줄    Y=122
초상화 띠     대체로 Y=144 이하
```

따라서 자막 한 줄의 16픽셀 높이는 대략 `Y=122-137`이고, 초상화 띠와
화면 좌표상 분리된다.

### VRAM 패턴 주소

그림을 구성하는 픽셀 패턴을 VRAM 어디에 저장하는지를 뜻한다.

```text
자막 패턴 고정 후보   $1600-$1ABF
필요 크기             19 × $40 = $4C0 word
```

화면에서 초상화와 안 겹쳐도 같은 VRAM 패턴 주소를 게임과 자막이 동시에 쓰면
그림이나 자막이 깨진다. 그래서 화면 배치 실측과 VRAM 빈공간 조사를 둘 다 했다.

---

## 2. 초상화 자리 실측

측정 Lua:

```text
lua/SUB/0.4.24.lua
```

키별 캡처 분류:

```text
Q = L       W = C       E = R
A = LC      S = LR      D = CR
F = LCR     G = NONE    R = OTHER
```

대표 결과:

```text
L 기준 X anchor   24
C 기준 X anchor   96
R 기준 X anchor   168
자리 간격         72px
각 초상화 틀      약 64×64px
```

실제 얼굴은 16×16/32×32 sprite 여러 장과 BAT 배경이 결합되므로 캡처된 sprite
bounding box는 인물·표정·조합에 따라 조금 달라진다. 하지만 배치 anchor는
L/C/R 세 자리로 유지됐다.

완료한 배치:

```text
NONE
L
C
R
LC
LR    ← 가운데 한 자리 건너뛴 조합
CR
LCR
```

최종 캡처 로그:

```text
dump/sub_0_4_24_portrait_mask_20260828_174504_slots.tsv
dump/sub_0_4_24_portrait_mask_20260828_174504_groups.tsv
```

`OTHER`로 분류할 예상 밖 배치는 사용자 전수 확인 범위에서 발견되지 않았다.

---

## 3. 모든 초상화 배치의 공통 VRAM 빈공간

측정 Lua:

```text
lua/SUB/0.4.25.lua
```

각 캡처마다 다음을 전부 사용 중으로 표시했다.

- BAT 테이블 자체
- BAT가 참조하는 모든 BG 패턴
- SATB 테이블 자체
- SATB의 64개 sprite가 크기까지 포함해 참조하는 모든 패턴

그 뒤 19글자 블록이 들어갈 수 있는 빈 범위의 교집합을 계산했다.

9회 캡처 결과:

```text
캡처 배치             LC, L, LR, C, LC, R, CR, LCR, NONE
마지막 공통 후보 수   56
첫 공통 후보          $1600-$1ABF
```

정본 로그:

```text
dump/sub_0_4_25_common_vram_20260828_180633_summary.tsv
dump/sub_0_4_25_common_vram_20260828_180633_candidates.tsv
```

별도의 `NONE` 단독 재확인에서도 첫 후보는 동일했다.

```text
dump/sub_0_4_25_common_vram_20260828_183845_summary.tsv
```

---

## 4. `$1600-$1ABF` 수명 감시

정지 화면 한 장에서 비어 있는 것만으로는 부족하다. 장면 전환 뒤 게임이 그
주소를 새로 사용할 수 있기 때문에 전체 수명 감시를 했다.

측정 Lua:

```text
lua/SUB/0.4.26.lua
```

감시 항목:

```text
W   대상 VRAM 범위에 실제 write가 있었는가
B   BAT가 대상 범위를 참조했는가
S   SATB가 대상 범위를 참조했는가
```

화면의 `W:0 B:0 S:0`이 초록색이면 그 시점까지 세 항목 모두 0이라는 뜻이다.
하나라도 발생하면 빨간색으로 바뀌며 로그에 주소와 slot이 남도록 만들었다.

엔딩을 포함해 장시간 켜둔 최종 결과:

```text
frames             147,247
callback writes          0
unique written words     0
BAT reference scans      0
SATB reference scans     0
reference scans      14,725
result              SUMMARY_PASS
```

60fps 기준 약 40분 54초 분량이다.

정본 로그:

```text
dump/sub_0_4_26_vram_lifetime_20260828_185553.tsv
```

마지막 행:

```text
147247  SUMMARY_PASS  0  0  1600  1ABF  0  0
```

---

## 5. 실제 자막을 고정 경로에 넣는 시험

### Lua all-voice 시험

```text
lua/SUB/0.4.27.lua
```

- 모든 실제 rate-`$0E` ADPCM을 이미 검증된 dummy 자막으로 연결한다.
- helper/renderer의 패턴 주소를 `$1600-$1ABF`로 고정한다.
- 실제 음성 재생과 게임 코드는 건너뛰지 않는다.

### 옛 `$7900` 경로와의 이중 출력 검사

```text
lua/SUB/0.4.28.lua
```

목표는 새 `$1600` 경로만 쓰고 옛 `$7900` 경로가 동시에 살아 있지 않은지
확인하는 것이었다. 남아 있는 세 로그는 충분한 강제 음성이 잡히지 않아
`SUMMARY_PASS` 증거로 사용하지 않는다.

```text
dump/sub_0_4_28_dual_path_20260828_192221.tsv
dump/sub_0_4_28_dual_path_20260828_192559.tsv
dump/sub_0_4_28_dual_path_20260828_192613.tsv
```

마지막 로그의 `SUMMARY_FAIL`은 옛 경로 충돌이 검출됐다는 뜻이 아니라,
새 경로 write/ref도 0이라 시험 조건 자체가 성립하지 않았다는 뜻이다.

### 진단용 디스크 시험판

```text
build/patch/TEST/0.4.6.11-allvoice-vram1600/
```

특징:

```text
파일명                 안정판과 동일, 기존 save 사용 가능
Lua                    불필요
모든 rate-$0E 음성     같은 dummy 2줄 자막 출력
VRAM                   $1600-$1ABF 고정
용도                   진단 전용, 출하용 아님
```

생성 도구:

```text
tools/build_allvoice_vram1600_test_0_4_6_11.py
```

---

## 6. 깨진 장면을 해석할 때의 주의점

시험 중 특정 장면에서 오른쪽 초상화/UI가 깨졌지만, 그 장면은 원래 게임
자막도 이미 깨지던 장면이었다. 원래 자막 경로와 새 경로가 함께 살아 있으면
새 `$1600` 경로의 안전성만 분리해서 판정할 수 없다.

그래서 다음 원칙을 세웠다.

- 원래 자막이 있는 장면의 기존 깨짐만으로 `$1600` 실패 판정을 하지 않는다.
- 가능하면 자막이 전혀 없는 깨끗한 기준판에서 Lua만으로 새 자막을 올린다.
- 다른 화면에서 깨지지 않고 특정 기존 장면에서만 깨진 결과는 기존 경로의
  문제일 가능성을 먼저 본다.
- 최종 판정은 모든 실제 자막을 연결한 출하 후보를 처음부터 전수 확인하면서
  한다.

깨끗한 기준판 시험용으로 아래 Lua도 만들었지만, 이 둘은 최종 근거가 아니라
진단 보조 도구다.

```text
lua/SUB/0.4.29.lua   no-subtitle 진단 BIOS의 gate를 Lua에서만 잠시 연다
lua/SUB/0.4.30.lua   진짜 pre-subtitle 0.4.5.9 base에 AC 팩을 Lua로 직접 적재
```

---

## 7. 최종 결정

현재 구현 방침:

```text
화면 위치       한 줄 Y=122 유지
초상화 위치     L/C/R 고정 배치로 취급
패턴 저장       VRAM $1600-$1ABF 고정
allocator       코드와 실험 자료는 보존, 현재 기본 경로에서는 사용하지 않음
검증 방식       실제 자막 전부 연결 후 게임 처음부터 전수 플레이
충돌 발견 시    해당 장면 로그를 근거로 allocator 또는 다른 고정 후보 재검토
```

고정 경로를 택한 이유:

1. 초상화의 화면 배치가 세 자리로 고정되어 있다.
2. 그 8개 조합을 모두 포함한 BAT+SATB 교집합에서 `$1600-$1ABF`가 비었다.
3. 147,247프레임 수명 감시에서 write/BAT/SATB가 전부 0이었다.
4. allocator는 매 조각 스캔 비용과 미래 점유 문제를 추가한다.
5. 현재 자료로는 고정 경로가 더 단순하고 충분히 유력하다.

다만 게임 전체를 아직 `$1600` 실제 자막으로 전수 확인한 것은 아니다.
따라서 이것은 **현재 채택된 출하 후보 경로**이지 수학적으로 영구 안전이
증명된 주소라는 뜻은 아니다. 실제 충돌이 드러나면 숨기지 말고 allocator를
다시 연결하는 편이 낫다는 것이 최종 합의다.

---

## 8. 다음에 바로 볼 파일

```text
lua/SUB/0.4.24.lua
lua/SUB/0.4.25.lua
lua/SUB/0.4.26.lua
lua/SUB/0.4.27.lua
tools/build_allvoice_vram1600_test_0_4_6_11.py
dump/sub_0_4_24_portrait_mask_20260828_174504_groups.tsv
dump/sub_0_4_25_common_vram_20260828_180633_summary.tsv
dump/sub_0_4_26_vram_lifetime_20260828_185553.tsv
build/patch/TEST/0.4.6.11-allvoice-vram1600/TEST_MANIFEST.json
```

관련 종합 기록:

```text
docs/handoff/SNATCHER_ALLOCATOR_CDDA_2026-08-28.md
docs/handoff/SNATCHER_VOICE_SUBTITLE_RUNTIME_2026-08-28.md
```
