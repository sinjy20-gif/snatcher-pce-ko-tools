# Snatcher PCE-CD 동적 한글 glyph 공급 구조 연구 인계서

작성일: 2026-08-13  
대상: Snatcher PCE-CD 한국어화 0.3.0 계열  
성격: 조사·설계 인계서. 구현 및 POC 결과가 아님.

## 1. 이 문서의 목적

현재 UI 한글화에서는 완성형 glyph를 대량으로 정적 상주시킬 때 데이터 규모와 런타임 배치 문제가 발생한다. 한편 기존 한글 자모조합기는 약 174개의 contextual component로 현대 한글 전체를 표현할 가능성이 있지만, Galmuri11 완성형과 동일한 pixel-exact 결과는 보장하지 않는다. 품질을 높이려면 174+α variant가 필요할 수 있다.

이 연구의 목적은 “동적 폰트를 반드시 만든다”가 아니라 다음 두 선택지 중 현재 엔진에 더 단순하고 안정적인 쪽을 판단할 증거를 모으는 것이다.

1. 완성형 bitmap을 Arcade Card(이하 AC)에 저장하고 UI/장면에서 필요할 때 공급한다.
2. 174+α contextual component를 CPU측에서 조합한다.

이번 단계에서는 ROM, 빌더, hook을 수정하지 않았고 POC도 만들지 않았다. 코드, 기존 로그, manifest, 메모리맵, UI 0.4.6/0.5.6 및 0.3.0 계열 소스를 읽기만 했다.

## 2. 요약 결론

### 2.1 UI만 놓고 본 결론

초기 분류 A/B/C/D 중에서는 **B에 가장 가깝다.**

> glyph 단위 AC 공급은 기술적으로 가능하지만, 모든 정책을 renderer miss handler에 넣기보다 label 또는 screen/UI-group 단위로 필요한 glyph identity와 주소를 준비하는 구조가 현실적이다.

다만 여기서 “화면별 공급”은 화면마다 CD에서 32바이트를 읽는다는 뜻이 아니다.

```text
CD -> AC       atlas 또는 glyph pack을 비교적 큰 단위로 적재
AC -> WRAM     화면 출력 시 필요한 32바이트 glyph만 공급
WRAM -> renderer  기존 $69FC 경로 사용
```

### 2.2 게임 전체를 놓고 본 결론

현재 UI에서 확인된 고유 한글 462개는 전체 게임의 최종 glyph 수가 아니다. 아직 대사의 절반 가까이가 추가될 예정이므로, 최종 전역 atlas 크기와 최초 CD 적재 시간은 아직 확정할 수 없다.

게임 전체의 최종 구조로는 다음 혼합형이 가장 유력하다.

1. 자주 쓰는 공통 glyph만 AC에 초기 적재한다.
2. 희귀 glyph는 scene/UI-group pack으로 분리한다.
3. scene record를 읽을 때 해당 glyph pack도 함께 AC에 적재한다.
4. renderer는 CD가 아니라 AC에서 32바이트씩 공급받는다.

전체 게임 관점의 최종 결론은 전체 번역 corpus의 고유 glyph inventory와 CD/AC 실측이 나오기 전까지 확정해서는 안 된다.

## 3. 가장 중요한 신규 발견: 0.3.0 atlas와 resident pack의 주소 충돌

사용자 실측:

- 989개에 가까운 UI를 올린 0.3.0에서 글자 깨짐과 glyph 하나 누락 등이 발생했다.
- UI를 26개 수준으로 되돌리면 다시 정상 동작했다.

처음에는 AC 전체 저장용량보다 cache/index 문제를 우선 의심했지만, `ac_0.1.14`와 `0.3.0` manifest를 대조한 결과 **AC 주소 배치의 명확한 중첩**이 확인됐다.

### 3.1 manifest 대조

| 항목 | ac_0.1.14 | 0.3.0 |
|---|---:|---:|
| atlas 시작 | `$10360` | `$10360` |
| atlas glyph 수 | 717 | 1,089 |
| atlas 크기 | 22,944B = `$59A0` | 34,848B = `$8820` |
| atlas 끝(배타) | `$15D00` | `$18B80` |
| resident common 시작 | `$16000` | `$16000` |
| 결과 | `$300` 여유 | `$2B80` 중첩 |

계산:

```text
0.3.0 atlas end
$10360 + $8820 = $18B80

resident pack start
$16000

overlap
$16000-$18B7F = $2B80 = 11,136 bytes
11,136 / 32 = 348 glyph 분량
```

0.3.0 manifest의 resident pack 배치는 다음과 같다.

```text
speaker pack  destination $16000
UI pack       destination $18000
```

따라서 atlas 후반 `$16000-$18B7F`는 speaker pack 전체 구간 및 UI pack 앞부분과 주소를 공유한다. 적재 순서에 따라 atlas 후반 또는 record 데이터가 덮인다. 실제 증상인 일부 글자 깨짐·특정 glyph 누락과 일치하는 강한 증거다.

### 3.2 현재 레이아웃의 안전한 atlas 상한

```text
($16000 - $10360) / 32 = 741 glyph
```

현재 배치에서는 741 glyph까지가 안전한 상한이다. 0.3.0의 1,089개는 정확히 348개 초과한다.

### 3.3 빌더가 이를 잡지 못한 이유

현재 compact/atlas 빌더는 다음 조건을 검사한다.

```python
if (ATLAS_AC & 0xFFFF) + len(atlas) > 0xFF00:
    raise RuntimeError("atlas crosses the 16-bit window the helper assumes")
```

즉 다음은 검사한다.

- 16-bit atlas offset window를 넘는지
- `$FFFF` sentinel과 충돌하는지
- compact record를 704바이트로 재구성했을 때 원본과 byte-exact인지

하지만 다음은 검사하지 않는다.

- `ATLAS_AC + atlas_bytes <= COMMON_DATA_BASE`인지
- atlas와 speaker/UI/shared resident pack이 겹치는지

따라서 `byte_exact_verified=2085`가 성립해도 런타임 AC 주소 배치는 깨질 수 있다.

### 3.4 이 발견의 정확한 의미

0.3.0 실패는 “AC의 2MiB 물리적 용량이 모자랐다”가 아니다. 하지만 **현재 atlas에 예약된 `$10360-$15FFF` 창이 모자라 resident 영역을 침범한 것**이므로, 구현 관점에서는 atlas bitmap 저장구간 부족이 맞다.

동적 font를 연구하기 전에 반드시 다음 중 하나가 필요하다.

- `COMMON_DATA_BASE`를 atlas 끝 이후로 이동
- atlas를 다른 비중첩 AC 구역으로 이동
- 공통 atlas와 scene glyph pack을 분리
- atlas/resident 구간 중첩을 build-time fatal error로 검사

## 4. 현재 UI font pipeline

확인된 호출 관계:

```text
UI renderer
  $6484  $FA/$FB = $3B80 설정
  $648C  font lookup 호출
      |
      +-- native Japanese code -> $69C2
      |       +-- cache hit: $00/$01 = bitmap pointer
      |       +-- $69FC
      |       +-- cache miss: A=$FF, X=sentinel/free-entry byte offset
      |
      +-- private Korean code
              +-- 완성 glyph를 CPU-visible buffer에 준비
              +-- $00/$01 = glyph source
              +-- $69FC
              +-- A=0 반환
```

### 4.1 `$648C`

- UI renderer의 font lookup 호출 지점이다.
- UI 0.5.6에서는 기존 `$7F50` 호출을 Bank 68 wrapper `$5CE7`로 바꿨다.
- custom glyph가 성공하면 `A=0`으로 반환해 뒤의 native miss fetch `$E060`을 건너뛴다.
- private code가 아니면 `$69C2`로 그대로 통과시킨다.

### 4.2 `$69C2`

- native Japanese font cache lookup이다.
- `$6A07`부터 4바이트 엔트리를 순회한다.

```text
+0 code byte 1
+1 code byte 2
+2 glyph bitmap pointer low
+3 glyph bitmap pointer high
```

- cache hit이면 pointer를 `$00/$01`에 넣고 `$69FC`를 호출한다.
- miss이면 `A=$FF`로 반환한다.
- miss 시 `X`는 sentinel/free-entry의 byte offset 상태로 남는다.

### 4.3 `$69FC`

실제 disassembly는 32바이트 source copy다.

```asm
LDY #$00
loop:
    LDA ($00),Y
    STA ($FA),Y
    INY
    CPY #$20
    BNE loop
RTS
```

- 입력 source pointer: `$00/$01`
- destination pointer: `$FA/$FB`
- UI renderer에서는 `$FA/$FB=$3B80`
- `$69FC` 자체는 `X`를 사용하지 않는다.

주의: `$69FC`가 X를 사용하지 않는 것과 `$69C2` miss의 X가 후속 native fetch에 필요하다는 것은 별개다. native fallback 주변에 임의의 `PHX/PLX`를 추가하면 안 된다.

### 4.4 `$00/$01`

- `$69FC`에 전달하는 16-bit glyph source pointer다.
- custom 공급기는 최종 32바이트 glyph가 있는 CPU-visible 주소를 넣으면 된다.
- UI 0.4.6/0.5.6에서는 `$3FE0`을 전달했다.

### 4.5 `$3FE0-$3FFF`와 `$3FC0-$3FDF`

- `$3FE0-$3FFF`: 32바이트 16×16 scratch glyph
- `$3FC0-$3FDF`: 기존 scratch 내용 백업
- 성공한 UI 0.4.6/0.5.6 경로는 custom glyph 호출 뒤 scratch를 복원했다.

### 4.6 `$3FA0-$3FA5`

세대 구분이 필요하다.

UI 0.4.6 성공 POC:

- 세 component pointer의 임시 저장에 사용
- 기존 6바이트를 CPU stack에 보존하고 호출 뒤 복구

UI 0.5.6:

- `$3FA0-$3FA5`를 사용하지 않음
- compositor 변수는 `$5DC4-$5DC9`로 이전

따라서 `$3FA0-$3FA5`는 0.4.6 POC 이력이지 0.5.6의 활성 할당이 아니다.

## 5. native Japanese 23-slot cache

raw ROM disassembly 및 probe 소스에서 확인된 구조:

```text
$6A07-$6A62  23 entries x 4 B = 92 B
$6A63        FFFF sentinel 시작
```

일부 오래된 문서의 24-slot 표기는 off-by-one 또는 구버전으로 판단된다. 실제 lookup 범위는 23개다.

### 5.1 한글 cache로 재사용 가능한가

구조적으로는 가능성이 있다. 엔트리에 custom code와 bitmap pointer를 넣으면 `$69C2`가 같은 형태로 찾을 수 있다.

그러나 현재는 권장하지 않는다.

- native Japanese fetch가 이 table을 어떤 시점에 초기화·삽입·교체하는지 실측 로그가 없다.
- archive에는 probe 스크립트만 있고 실제 `PROBEUI` 결과가 없다.
- Japanese glyph와 한글 glyph가 23개를 공유하면 native fallback을 훼손할 수 있다.
- UI runtime burst 예비 분석에서 고유 한글이 23개를 넘는 사례가 있다.
- `$69C2` miss의 X가 후속 native fetch ABI 일부이므로 wrapper가 섣불리 개입하기 어렵다.

첫 설계에서는 native cache를 소유하지 말고, private code만 별도 공급한 뒤 non-private code를 `$69C2`로 통과시키는 것이 안전하다.

## 6. 현재 AC glyph 공급 경로

현재 compact helper는 이미 global atlas의 glyph를 AC에서 CPU WRAM으로 옮긴다.

AC 주소 설정:

```text
$1A02-$1A04  24-bit AC address
$1A07        increment
$1A08/$1A09 control
$1A00        data port
```

glyph copy:

```asm
TII $1A00,destination,$0020
```

즉 AC에서 32바이트 glyph 하나를 CPU-visible WRAM으로 가져오는 데이터 경로는 이미 존재하고 현재 빌더가 사용 중이다.

### 6.1 bank mapping

- 이미 AC에 올라간 atlas를 `$1A00` port로 읽을 때는 `TAM/TMA`가 필요하지 않다.
- MPR4 mapping은 BIOS CD_READ로 CD 데이터를 AC에 적재하는 bulk transfer 단계의 문제다.
- per-glyph AC->WRAM 공급은 AC port 접근이므로 renderer의 bank mapping을 바꾸지 않아도 된다.

### 6.2 현재 local record/cache 구조

```text
$5B80-$5BDF  text/metadata 96 B
$5BE0-$5E3F  glyph/cache 영역 19 x 32 B = 608 B
```

- slot 0: period
- slot 1: blank
- slot 2: ellipsis
- slot 3-17: 실제 glyph, 최대 15개
- slot 18: fractional-space helper와 관련된 영역

현재 font wrapper가 해석하는 local code는 `F040-F052`, 총 19개다. 실제 한글용은 예약 slot을 제외해 최대 15개다.

## 7. glyph 단위 공급 비용

AC miss에서 scratch를 거쳐 기존 renderer로 전달하면 최소 작업은 다음과 같다.

1. private glyph identity 해석
2. atlas index 또는 24-bit AC 주소 계산
3. AC port 설정
4. `TII $1A00,$3FE0,$20`
5. `$00/$01=$3FE0`
6. `$69FC`로 `$3FE0->$3B80` 32바이트 복사
7. 필요하면 `$3FC0-$3FDF`에서 scratch 복원

데이터 이동량:

```text
AC -> scratch       32 B
scratch -> renderer 32 B
합계                64 B 상당
```

HuC6280 일반 timing에 따르면 32바이트 TII 자체는 약 200 cycle대라는 계산이 가능하지만 프로젝트 실측값은 아니다. lookup, 주소 설정, scratch 보존, hook, redraw 누적 비용이 별도로 필요하다.

기존 실측 비교:

| 경로 | 측정 cycles/glyph |
|---|---:|
| precomposed UI 0.3.0 | 약 866-1288 |
| compositor 0.6.1 | 약 2883-3007 |
| compositor 0.6.0 | 약 3690-3962 |

AC 32바이트 전송은 조합기의 약 +2000 cycle보다 작을 가능성이 높지만, 아직 AC miss 전체 경로를 실측한 것은 아니다.

## 8. private code/index 폭

현재 실제 wrapper:

```text
F040-F052 = 19 local identities
예약 slot 제외 실제 한글 최대 15
```

하지만 parser/codec이 허용하는 전체 private 영역은 더 크다.

```text
lead   F0-F7 = 8
trail  40-7E 및 80-FC = lead당 188
총     8 x 188 = 1504
예약 3개 제외 = 1501 identities
```

따라서 현재 UI의 462개 고유 한글은 private code 폭에 들어간다. 현재 문제는 전체 code 폭이 아니라 wrapper가 local 19-slot만 해석하는 점이다.

전체 현대 한글 11,172자를 모두 직접 code화하기에는 1501개가 부족하다. 그러나 현재 게임 corpus에 실제 등장하는 고유 음절만 다룬다면 별도 inventory 결과에 따라 판단할 수 있다.

동적 공급 시 가능한 identity 구조:

- `F0-F7 + trail` 자체를 안정적 global glyph ID로 사용
- `AC_BASE + ID*32`로 직접 계산
- bitmap dedup 때문에 주소가 비연속이면 AC의 ID->offset table 사용
- 화면/scene 진입 시 필요한 ID->offset만 작은 WRAM table로 prefetch

## 9. 화면별/UI-group별 glyph 수

UI 데이터만 계산한 기존 값:

- 번역 UI 행: 989개
- 고유 한글 완성형: 462개
- 순수 bitmap: `462*32=14,784B`, 약 14.44KiB

주의: 이 462개는 UI만의 수치이며 대사 전체의 최종 atlas 수가 아니다.

`runtime_ui_strings_raw.tsv`를 frame 간격 120 이상에서 나누는 임시 burst 분석 결과:

- burst 155개
- 중앙값 8 glyph
- 평균 약 9.6 glyph
- 90 percentile 17 glyph
- 최대 36 glyph

이 값은 정확한 동시 화면 수가 아니다. 연속 submenu가 합쳐졌을 수 있다.

정확한 수를 얻으려면 collector가 다음을 기록해야 한다.

- 올바른 `$3490-$3498` UI 상태
- `$3497` group
- `$3498` row/item
- `$3499/$349A` source pointer
- menu open/close 및 scene transition
- selection에 따른 동일 label redraw
- raw Japanese source와 `ui_text` 대응

현재 collector 일부는 header에 `$3610`을 사용한 흔적이 있어 기존 dump만으로 정확한 screen grouping을 확정하기 어렵다.

## 10. 최초 CD 적재량과 로딩 시간

### 10.1 ac_0.1.14와 0.3.0 비교

| 항목 | ac_0.1.14 | 0.3.0 |
|---|---:|---:|
| 초기 공통 적재 | 11 x 8KiB = 88KiB | 13 x 8KiB = 104KiB |
| UI resident pack | 8KiB | 124,928B, 약 122KiB |
| 전체 resident pack | 약 48KiB | 약 172KiB |
| 초기+resident 합계 | 약 136KiB | 약 276KiB |

atlas만의 증가:

```text
22,944B -> 34,848B
initial chunks 11 -> 13
```

atlas 증가 때문에 늘어난 것은 약 16KiB, 8KiB 호출 두 번이다. 기존 측정치인 BIOS CD_READ 호출당 약 188ms를 적용하면 호출 overhead 증가는 약 0.38초로 추정된다.

더 큰 증가는 UI compact record다.

```text
ac_0.1.14 UI  59 records,   8KiB transfer
0.3.0 UI     962 records, 122KiB transfer
```

따라서 0.3.0의 큰 최초 로딩 증가가 있다면 atlas 12KiB 증가만이 아니라 962개 UI record의 resident 적재가 주원인이다.

### 10.2 규모별 atlas 초기 적재 예상

| 대상 | bitmap 크기 | 8KiB chunk 개수(대략) |
|---|---:|---:|
| UI 고유 한글 462개 | 14,784B | 2 |
| 0.3.0 atlas 1,089개 | 34,848B | 5 |
| 현대 한글 전체 11,172개 | 357,504B | 44 |

현대 한글 전체 완성형을 무조건 초기 적재하면 기존 188ms/call 수치를 단순 적용했을 때 호출 overhead만 약 8.3초다. variant가 추가되면 더 커진다. 이 방식은 권장할 수 없다.

반면 현재 UI 462개만 독립 atlas로 적재하면 약 14.8KiB이므로 두 chunk 수준이다. 하지만 전체 대사 atlas와 합치면 최종 수치는 다시 계산해야 한다.

## 11. 아직 추가될 대사의 영향

현재 0.3.0 manifest:

- 전체 compact record: 2,085개
- global unique bitmap: 1,089개
- atlas: 34,848B
- UI record: 962개

남은 대사가 추가되면 두 축이 증가한다.

1. 새로운 문자열 record: record당 128B
2. 처음 등장하는 bitmap: glyph당 32B

대사가 두 배가 되어도 glyph 수가 정확히 두 배가 되지는 않는다. 이미 사용한 음절은 재사용되므로 고유 glyph 증가율은 점차 낮아진다. 그러나 현재 1,089개를 최종 atlas 규모로 간주해서는 안 된다.

또한 atlas는 bitmap 자체를 key로 dedup한다. 따라서 “한글 문자 수”와 “atlas bitmap 수”가 항상 정확히 일치한다고 가정해서도 안 된다. variant나 서로 다른 모양이 존재하면 같은 문자도 여러 bitmap이 될 수 있다.

최종 설계 전에 필요한 inventory:

- 현재 review 포함 corpus의 고유 Hangul
- 번역되어 있으나 아직 미포함된 corpus의 고유 Hangul
- 향후 번역 예정 대사의 일본어 source를 기반으로 한 예상 음절 집합은 직접 계산할 수 없으므로 번역 진행 후 반복 집계
- UI/BODY/speaker/특수 glyph의 합집합
- bitmap dedup 후 실제 atlas glyph 수
- scene별 공통/희귀 glyph 빈도

## 12. 공급 정책 비교

### 12.1 glyph마다 AC miss 공급

장점:

- 큰 CPU bitmap cache가 필요하지 않다.
- pixel-exact glyph를 그대로 사용할 수 있다.
- AC의 넓은 주소공간을 사용할 수 있다.

단점:

- 반복 redraw마다 AC 주소 해석과 전송이 발생한다.
- global ID resolver와 address table이 필요하다.
- 현재 Bank 69 helper 여유가 73바이트뿐이다.
- font wrapper 인접 공간도 매우 작다.
- scratch 재진입 및 IRQ 영향이 미확인이다.

### 12.2 label 단위 bitmap prefetch

장점:

- 현재 15-glyph local pack과 가장 가깝다.
- 기존 helper가 이미 record별 glyph를 AC에서 가져온다.
- renderer는 현재 local F040-F052 wrapper를 거의 그대로 사용할 수 있다.

단점:

- label당 15개를 넘으면 format 확장이 필요하다.
- label이 자주 교체되면 반복 prefetch가 발생한다.

### 12.3 screen/UI-group bitmap 전체 prefetch

장점:

- 화면 동안 AC 접근이 적다.

단점:

- 예비 최대 36 glyph라면 `36*32=1152B` CPU RAM이 필요하다.
- 현재 608B local cache에 들어가지 않는다.
- native 23-slot에도 들어가지 않을 수 있다.

### 12.4 screen/UI-group 주소 table prefetch + 단일 scratch streaming

장점:

- bitmap 전체를 WRAM에 저장하지 않아도 된다.
- group에 필요한 ID와 AC offset만 작은 table로 준비할 수 있다.
- 실제 glyph는 `$3FE0` 하나로 공급한다.
- pixel-exact 품질이 유지된다.

단점:

- glyph마다 AC->scratch 복사는 남는다.
- 주소 table과 resolver code 공간이 필요하다.
- redraw 실측이 필요하다.

### 12.5 native 23-slot 공유

현재로서는 비권장이다. Japanese fallback 훼손 위험과 cache lifecycle 미확인이 크다.

## 13. 권장 확장 구조

전체 대사가 계속 늘어난다는 조건에서는 다음 구조가 가장 확장성이 높다.

```text
[초기 공통 적재]
  directory/state
  자주 쓰는 공통 glyph atlas
  공통 UI glyph 또는 최소 UI core

[scene 진입]
  scene compact records
  해당 scene의 희귀 glyph pack
  scene glyph ID -> AC offset metadata

[UI group 진입]
  필요한 glyph ID/address 목록 결정
  작은 label이면 기존 local bitmap cache 사용
  큰 group이면 address table + $3FE0 streaming

[glyph 출력]
  private code -> AC glyph -> $3FE0 -> $69FC
  Japanese code -> $69C2
```

핵심은 CD access를 glyph 단위로 하지 않는 것이다. 32바이트라도 CD seek/BIOS call overhead가 크므로, CD->AC는 scene/group pack 단위로 묶어야 한다. 실제 렌더링 시에는 이미 AC에 있는 glyph만 사용한다.

공통 glyph 선정은 단순 빈도뿐 아니라 다음도 고려해야 한다.

- 시스템 메뉴처럼 여러 scene에서 반복되는 UI
- 저장/불러오기 및 옵션
- 빈번한 조사/행동 명령
- 화자명
- 자주 반복되는 조사와 어미 음절
- scene 전환 중 반드시 즉시 표시되는 문자열

## 14. 174+α compositor와 비교

확인된 수치:

- 174 component: `174*32=5,568B`
- UI pixel-exact 462 glyph: 14,784B
- 현재 0.3.0 global bitmap: 34,848B
- compositor는 precomposed 경로보다 glyph당 약 2,000 cycle 추가가 관찰됨

174+α의 장점:

- 전체 현대 한글 coverage에 유리
- AC나 대규모 완성형 bitmap 없이도 확장 가능
- 최종 고유 음절 수가 매우 커질 때 저장 효율이 높다

174+α의 단점:

- 일반 174 조합기가 Galmuri11 완성형과 pixel-exact라는 증거가 없다.
- 품질을 높이면 variant와 selection rule이 늘어난다.
- renderer 호출 시 합성 비용이 든다.
- UI 0.4.6 성공은 일반 174 조합 검증이 아니라 7개 완성형에서 추출한 정확한 component 조합이었다.

완성형 AC 공급의 장점:

- Galmuri11 pixel-exact 품질을 직접 보장할 수 있다.
- AC->WRAM 32바이트 경로가 이미 존재한다.
- 조합 및 variant selection이 필요 없다.

완성형 AC 공급의 단점:

- final corpus가 커지면 global atlas와 최초 CD 적재가 증가한다.
- 현재 0.3.0처럼 AC layout 경계검사가 없으면 데이터가 서로 덮인다.
- scene/group pack과 global ID 설계가 필요하다.

현재는 완성형 group supply 쪽이 UI에는 더 유리하지만, 전체 게임 최종 corpus 크기에 따라 174+α 또는 혼합형을 다시 비교해야 한다.

## 15. Japanese fallback와 UI 상태 보존 조건

동적 공급이 성공하더라도 다음 규칙을 유지해야 한다.

1. parser-safe private code만 custom 공급기로 분기한다.
2. non-private Japanese code는 `$69C2`로 그대로 보낸다.
3. custom 성공 시 `A=0`으로 반환한다.
4. `$FA/$FB` renderer destination을 불필요하게 변경하지 않는다.
5. `$3FE0-$3FFF`를 빌리면 기존 성공 POC처럼 복원한다.
6. `$3471/$3472` source pointer와 terminator 처리에 개입하지 않는다.
7. glyph supplier는 BAT, VRAM address, palette, selection state를 직접 만지지 않는다.
8. AC port copy를 위해 MPR을 변경하지 않는다.
9. native `$69C2` miss의 X 출력 ABI를 보존한다.

이 조건을 지키면 glyph 공급기 자체가 Japanese fallback이나 메뉴 selection/BAT/palette를 훼손할 이유는 없다. IRQ 중 scratch 재진입 여부는 별도 실측이 필요하다.

## 16. 확인된 사실 / 추론 / 아직 모르는 것

### 16.1 확인된 사실

- `$648C`가 UI font lookup 호출 지점이다.
- `$69C2`는 `$6A07`부터 23-entry native lookup을 수행한다.
- `$69FC`는 `$00/$01` source에서 `$FA/$FB` destination으로 32바이트를 복사한다.
- UI 0.4.6/0.5.6에서 `$3FE0` scratch를 `$69FC`에 넘기는 경로가 성공했다.
- 현재 AC helper가 `TII $1A00,destination,$20`으로 glyph를 WRAM에 복사한다.
- per-glyph AC port copy에는 MPR 변경이 필요하지 않다.
- 현재 local cache는 19 slot, 실질 한글 최대 15 slot이다.
- 0.3.0 atlas `$10360-$18B7F`와 resident pack `$16000...`이 겹친다.
- 현재 레이아웃의 atlas 안전 상한은 741 glyph다.
- 0.3.0은 1,089 glyph이므로 348 glyph 분량을 초과한다.
- 0.3.0 UI resident pack은 약 122KiB로 ac_0.1.14의 8KiB보다 크게 증가했다.

### 16.2 강한 추론

- 989개 수준 UI에서 나타난 glyph 깨짐·누락은 atlas/resident 주소 중첩으로 설명될 가능성이 매우 높다.
- UI를 26개로 줄여 정상화된 것은 고유 bitmap 감소로 atlas 끝이 `$16000` 아래로 돌아왔기 때문일 가능성이 높다.
- AC 32바이트 공급 비용은 compositor의 약 +2000 cycle보다 작을 가능성이 높다.
- 전체 bitmap을 WRAM에 prefetch하기보다 group 주소 table과 단일 scratch를 조합하는 방식이 현재 RAM 조건에 더 잘 맞는다.
- 전체 대사까지 전역 atlas로 최초 적재하면 최종 로딩시간과 layout 문제가 다시 커질 가능성이 높다.

### 16.3 아직 모르는 것

- UI를 26개로 되돌린 생존 빌드의 실제 `atlas_glyphs`, `atlas_bytes`, `atlas_end`
- 전체 번역 완료 후의 고유 Hangul 및 bitmap 수
- native 23-slot cache의 초기화·삽입·교체·화면 전환 수명
- AC miss 전체 경로의 실제 cycle
- UI/scene별 정확한 동시 glyph 수와 redraw 횟수
- `$3FC0-$3FFF`의 IRQ/reentrant 안전성
- dynamic resolver를 넣을 안전한 code/data 공간
- scene glyph pack을 기존 CD loading과 묶을 때의 실제 호출 수와 체감 지연

## 17. 다음 연구 순서

구현 전에 아래 순서로 증거를 확보하는 것이 좋다.

### 17.1 생존 빌드와 실패 빌드의 manifest 대조

26 UI 생존 빌드에서 다음을 기록한다.

```text
atlas_ac
atlas_glyphs
atlas_bytes
atlas_end
common_data_base
각 resident package destination/extent
initial_cd_chunks
UI resident transferred_bytes
```

확인 조건:

```text
atlas_end <= first_resident_start
```

### 17.2 build-time AC extent audit

아직 구현하지 말고, 설계상 검사해야 할 구간을 먼저 목록화한다.

- directory
- state page
- template
- global atlas
- speaker/UI/small/shared resident pack
- scene window
- 각 transfer의 sector/chunk padding extent

유효 byte 길이뿐 아니라 실제 BIOS transfer가 덮는 padded extent도 비교해야 한다.

### 17.3 전체 corpus glyph inventory

다음 세 집합을 별도로 산출한다.

- 현재 출하 대상
- 번역됐지만 review 때문에 미출하
- 향후 번역 완료 예상 전체

문자 집합과 bitmap dedup 결과를 모두 기록한다.

### 17.4 정확한 screen/scene grouping

runtime collector의 `$3490-$3498` capture를 바로잡고 화면/scene별 고유 glyph 집합을 계산한다.

### 17.5 read-only timing probe 설계

향후 POC 허가 후 다음 네 경로를 동일 화면에서 측정한다.

1. current local precomposed hit
2. AC->scratch->$69FC
3. small WRAM cache hit
4. 174+α compositor

평균뿐 아니라 worst-case menu redraw와 selection 이동을 측정해야 한다.

## 18. 구현 시 피해야 할 판단

- “AC가 2MiB이므로 아무 주소에나 atlas를 늘려도 된다.”
- “byte-exact reconstruction 검사가 통과했으므로 runtime layout도 안전하다.”
- “UI 462개가 게임 전체 최종 glyph 수다.”
- “대사량이 두 배면 glyph 수도 정확히 두 배다.”
- “화면별 공급이므로 glyph를 화면마다 CD에서 읽으면 된다.”
- “native cache가 23 slot이므로 한글도 그대로 끼워 넣으면 된다.”
- “`$69FC`가 X를 안 쓰므로 native fallback의 X도 보존할 필요가 없다.”
- “UI를 줄여 살아났으므로 renderer/index 문제는 전혀 없다.”

마지막 항목에 특히 주의한다. atlas 중첩은 명확한 버그지만, 이를 고친 뒤에도 local 15-slot, resolver code 공간, redraw 비용 같은 별도 한계가 남는다.

## 19. 주요 근거 파일

- `C:\snatcher\extraction\patch\static\build_ac_dynamic_0_1_14.py`
- `C:\snatcher\extraction\patch\static\build_full_overlay_patch.py`
- `C:\snatcher\extraction\translation\game_text_codec.py`
- `C:\snatcher\build\patch\ac_0.1.14\manifest.json`
- `C:\snatcher\_archive_2026-08-12\SNATCHER_KO_HANDOFF_2026-08-13\build\patch\0.3.0\manifest.json`
- `C:\snatcher\_archive_2026-08-12\SNATCHER_KO_HANDOFF_2026-08-13\extraction\patch\static\build_snatcher_ko_0_3_0.py`
- `C:\snatcher\_archive_2026-08-12\SNATCHER_KO_HANDOFF_2026-08-13\docs\00_PIPELINE_0.3.0.md`
- `C:\snatcher\_archive_2026-08-12\hangul_composer_handoff\reference\UI_0.4.6_proven_compositor.py`
- `C:\snatcher\_archive_2026-08-12\SNATCHER_KO_HANDOFF_2026-08-12\docs\02_UI_HANGUL_COMPOSER_UI_0.5.6_TECHNICAL_HANDOFF.md`
- `C:\snatcher\_archive_2026-08-12\SNATCHER_KO_HANDOFF_2026-08-12\UI_0.5.6_REPRO_COMPLETE\restart_kit\source\build_ui_0_5_6.py`
- `C:\snatcher\_archive_2026-08-12\UI_RESTART_KIT_2026-08-10\tools\mesen\PROBE_UI_NATIVE_FONT_CACHE.lua`
- `C:\snatcher\dump\runtime_ui_strings_raw.tsv`

## 20. 최종 인계 문장

현재 엔진에서는 AC에서 32바이트 완성형 glyph를 CPU-visible WRAM으로 가져와 `$69FC`에 전달하는 경로가 기술적으로 성립한다. 그러나 0.3.0의 대량 UI 실패는 단순한 renderer 문제가 아니라 global atlas가 `$16000` resident 영역을 침범한 명확한 AC layout 결함을 포함한다. 또한 아직 대사의 절반 가까이가 추가되어야 하므로 UI 462개나 현재 atlas 1,089개를 최종 규모로 사용할 수 없다.

따라서 다음 단계는 동적 font 구현이 아니라, 먼저 전체 corpus와 scene별 glyph inventory, AC extent map, 초기 CD_READ 비용을 확정하는 것이다. 그 결과를 바탕으로 공통 glyph 초기 적재와 scene/UI-group glyph pack을 결합한 완성형 공급 구조를 174+α compositor와 다시 비교해야 한다.
