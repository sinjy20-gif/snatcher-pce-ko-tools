# SNATCHER ADPCM native — 0.4.6.65 인계서

작성: 2026-09-02

## 오늘 확정한 것

### 1. 초상화 깨짐의 직접 원인과 수정

`0.4.6.64`는 key별 VRAM 안전자리표 자체가 아니라 **통합 native 빌더 연결**이
빠져 있었다.

현재 native directory는 route당 9 B다.

```text
LBA u24 BE + payload pointer u24 LE + VRAM 즉치값 3 B
```

그러나 CD-DA/ADPCM 통합 빌더
[`tools/build_snatcher_0_4_6_43_cdda_adpcm.py`](../../tools/build_snatcher_0_4_6_43_cdda_adpcm.py)는
구형 `len(directory) // 6`을 계속 사용했고 `imm_offsets`도
`native.make_armer()`에 전달하지 않았다.

결과적으로 directory에는 음성별 base가 있었지만 active AC renderer, CPU renderer,
helper control은 모두 기본 `$6600` (`6630BF`)에 남았다. 그래서 `$00309D`처럼
표가 `$4600` (`4630AF`)을 요구하는 음성도 `$6600`에 글리프를 써 초상화를 덮었다.

수정:

```python
len(directory) // 9
imm_offsets=(vram_base_hi_imm, pattern_base_lo_imm, pattern_attr_imm)
```

수정 빌드: `build/patch/0.4.6.65/`

실기 확인:

```text
0.4.6.64 / LBA 00309D
want=4630AF, AC=6630BF, CPU=6630BF  -> MISMATCH

0.4.6.65
키별 base 적용 성공, 초상화 깨짐 없음 (사용자 실기 확인)
```

### 2. 아직 남은 문제: LBA 감지 사각지대

`ADPCM_003143_FFFF_0E`는 자막 4조각 모두가 Studio/pack/directory에 있다.

```text
runtime key: FFFF0E400014
master LBA:  003123
safe base:   5200
directory:   5290AF
payload:     4 parts
```

하지만 실기 `0.5.114` 결과에서 이 음성이 재생될 때:

```text
actual key=FFFF0E400014
native slot=A2
slot LBA=003114       <- 직전 음성의 LBA
state=00
```

새 `$003123` CDB/LBA가 native slot에 `A1`로 들어오지 않는다. 따라서 native
armer는 새 directory route를 찾지 못하고 state를 열지 않으며, 이 대사의 4줄은
렌더러/scheduler까지 도달하지 않는다.

이 건은 VRAM base·4조각 scheduler·자막 pack 문제가 아니다. 현 native ADPCM
gate가 **새 CD LBA 포착**만으로 시작을 판정하는 구조의 사각지대다.

## 다음 작업

1. 기존 LBA route는 유지한다. 이 경로는 `.65`에서 key별 base와 초상화 안전성을
   확인했다.
2. LBA slot이 새 `A1`로 갱신되지 않는 ADPCM 시작용 fallback을 별도로 설계한다.
   판정 값은 이미 console key와 동일한 6 B 지문이다:

   ```text
   end address u16 LE + playback rate + ADPCM RAM samples at end/4, end/2, 5*end/8
   ```

3. fallback은 실제 ADPCM 시작 hook에서 지문을 얻고, runtime-key -> native route
   표를 조회해 기존 armer의 `arm_found` 이후 경로(미니 index/base/helper/state)를
   재사용해야 한다. Lua는 측정에만 쓰고 최종 path에는 넣지 않는다.
4. 첫 대상은 위 `FFFF0E400014` 하나다. 이 키가 native state=1 -> 2와 4조각
   전환을 완주하면 같은 fallback을 일반화한다.

## 별도 회귀 관측 (아직 원인 미확정)

`0.4.6.65`에서 key별 base 연결과 초상화 덮기는 해결됐지만, 실기에서 다음 두
증상이 다시 관측됐다.

- 뒷화면 소환
- 국장실 화면 떨림이 이전보다 심해짐

이는 이번 `$6600` base 연결 누락과 다른 축이다. 과거 해결 기록의 VDC/IRQ 및
상주 renderer 수명주기 회귀로 취급할 것. ADPCM LBA-fallback 작업과 섞어 고치지
말고, 먼저 `.65` 기준으로 재현 조건과 `SEI` 창/fragment 종료 시점을 다시 측정한다.

## 측정 Lua

모두 관찰 전용이며 키 입력을 요구하지 않는다.

| 파일 | 용도 |
| --- | --- |
| `lua/SUB/0.5.110.lua` | directory 기대값과 AC/CPU engine base 대조 |
| `lua/SUB/0.5.111.lua` | base write order/PC 기록 |
| `lua/SUB/0.5.112.lua` | state=1 직전 AC engine, state=2 뒤 CPU engine 비교 |
| `lua/SUB/0.5.113.lua` | `$003123` 4조각 scheduler 전용 관찰 |
| `lua/SUB/0.5.114.lua` | 실제 ADPCM 지문 vs native slot LBA/state |

관련 결과:

```text
dump/sub/adpcm_base_apply_0_5_110.tsv
dump/sub/adpcm_base_pre_copy_0_5_112.tsv
dump/sub/adpcm_actual_gate_0_5_114.tsv
```

## 환경 A에서 실행

1. `build/patch/0.4.6.65/Snatcher CD-ROMantic (Japan) [KO].cue`를 연다.
2. BIOS `Syscard3_galmuri_0.4.6.65.pce`를 고른다.
3. Power Cycle.
4. 관찰할 때만 해당 Lua 하나를 로드한다. 서로 겹쳐 로드하지 않는다.

`0.4.6.65`는 CUE가 가리키는 원본 Track 01~23도 필요하다. 홈에 기존 공용 원본
트랙이 있으면 홈 묶음의 Track 24 [KO], CUE, BIOS만 덮어쓴다.
