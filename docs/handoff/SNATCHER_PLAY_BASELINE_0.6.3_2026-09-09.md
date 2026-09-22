# SNATCHER 현재 플레이 기준판 0.6.3 — 2026-09-09

## 결론

게임 플레이에는 아래 한 폴더만 사용한다.

`build/patch/0.6.3`

- CUE: `Snatcher CD-ROMantic (Japan) [KO].cue`
- Android용 CHD: `Snatcher CD-ROMantic (K) [0.6.3].chd`
- BIOS: `Syscard3_galmuri_0.6.3.pce`
- BIOS 간편 사본: `Syscard3.pce`

`0.6.2`는 문제 비교와 복귀를 위한 이전 안정판으로 보존한다. 최근의 나머지
`0.6.3-*` 변형판은 플레이용이 아니다.

## 무엇을 0.6.3으로 승격했나

기존 `0.6.3-rc1-adpcm-delay`의 보존된 `subtitle_inputs`를 사용해 정상 빌드
사슬로 다시 만들었다. 핵심 수정은 ADPCM 첫 자막 조각의 시작 시간이 0보다
늦을 때 즉시 표시하지 않고 저장된 `start_frame`까지 기다리는 것이다.

예시 `ADPCM_003BD9_C000_0E / 당신, 누구야.`는 저장된 3.355초를 기존 규칙으로
201프레임(3.350초)에 맞춘다. 0초 시작 자막 경로는 유지한다.

재빌드 결과는 기존 rc1 폴더의 24개 트랙과 전부 SHA-256 동일했다. 기존 CHD도
같은 24개 트랙으로 만든 파일이므로 최종 폴더로 이동하고 버전명을 붙였다.

## 제외한 것

0.6.3에는 아래 실험을 넣지 않았다.

- GFX native payload와 BIOS/Track02 실행 훅
- ADPCM 132/138프레임 강제 반환
- `$180C/$180D` AD_STAT 진단 변경

공용 `patch_track24_subtitle_pack.py`도 GFX 파일이 존재한다는 이유만으로 payload를
자동 합성하지 않게 수정했다. GFX 전용 재현에서 `--include-gfx-payload`를 명시한
경우에만 넣는다. 최종 0.6.3은 이 옵션을 사용하지 않았다.

## 검증

- `test_adpcm_initial_delay.py`: 3 tests PASS
- `verify_adpcm_initial_delay_candidate.py`: PASS
- 실제 LBA route, 첫 시작 201f, duration, renderer/template, BIOS alias 확인
- CUE 참조 24개, 누락 0
- 최종 매니페스트 해시와 실제 파일 해시 일치
- 이전 `0.6.2` BIOS 불변 확인

SHA-256:

- BIOS `D13F452E4DA35E9EA7BBFCF63D5D40DDB1220BC7E889CA3EB6DE11FEE6580835`
- Track02 `6F12FE002BC2C798ADBE5E37AB58521D883D418BF307A8D024F27E0C6FBD4652`
- Track24 `38C89D1664DC5CECB3101465E13FFBD705B5806E5EF92E5D7588FB8FDA51ADA4`
- CUE `934455F721F0869A88FE7A7B5E4F3210E19B91E5A74A50D1F377315A2A22359F`
- CHD `08F83F274180FCC79B53BE3984C2CFABEC525C30B3C3082E5DFEBA4064D55C25`

## 실행 규칙

BIOS와 CUE/CHD를 반드시 같은 `0.6.3` 폴더의 것으로 맞춘다. BIOS를 바꾼 뒤에는
Mesen/RetroArch를 Power Cycle하고, GFX 실험판에서 만든 상태 저장은 불러오지
않는다. 게임 안에서 만든 일반 세이브로 진행을 복구한다. No Sprite Limit을 켠다.

## 알려진 문제

Android RetroArch에서 특정 ADPCM 직후 일반 대사 한 페이지만 일본어로 남는
호환성 문제가 있다. PC/Mesen에서는 정상이다. 이를 확인하려 만든 132/138 및
AD_STAT 진단판은 효과가 없었으므로 최종판에 넣지 않았다. 게임 진행을 막는
문제는 아니며 별도 호환성 백로그로 유지한다.

`현재 플레이 기준판`은 사용자의 버전 선택을 하나로 고정했다는 뜻이다. 모든
장면과 모든 분기의 전체 회귀 검증이 끝났다는 뜻은 아니다.

## 격리 처리

아래 폴더로 최근 실패/진단판 10개를 이동했다.

`build/patch/_FAILED_EXPERIMENTS_2026-09-09`

삭제하지 않았으므로 연구 목적으로 복구할 수 있지만 게임에는 사용하지 않는다.
세부 목록은 해당 폴더의 `README.txt`를 본다.
