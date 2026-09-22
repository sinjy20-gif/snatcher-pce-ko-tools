# 스내처 PCE-CD 오프닝 나레이션 오디오 경로 분석 인계서

## 1. 목적

현재 `runtime_text_audit.lua`는 일반 대사 음성 이벤트를 정상적으로 수집하고 있으나, **오프닝 시퀀스의 나레이션은 기존 음성 수집기에 잡히지 않는 문제**가 있었다.

기존 수집기의 음성 감지는 프레임마다 `cdrom.adpcm.playing` 상태를 확인하여 ADPCM 재생의 START/END를 기록하는 구조다.

따라서 오프닝 나레이션이 ADPCM이 아닌 별도의 CD 오디오 경로를 사용하는지 확인하는 작업을 진행했다.

---

## 2. 기존 일반 음성 수집 구조

`runtime_text_audit.lua`의 일반 음성 수집은 다음 Mesen 상태값을 사용한다.

```text
cdrom.adpcm.playing
cdrom.adpcm.readAddress
cdrom.adpcm.writeAddress
cdrom.adpcm.adpcmLength
cdrom.adpcm.playbackRate
```

`cdrom.adpcm.playing == true` 전환 시 START를 기록하고, 다시 false가 되면 END 및 재생 시간을 기록한다.

즉 일반 게임 대사는 **ADPCM 경로**를 사용하는 것이 이미 실측되어 있다.

---

## 3. 오프닝 나레이션 조사

오프닝에서 어떤 오디오 상태가 움직이는지 확인하기 위해 별도의 광범위 프로브를 작성하였다.

조사 결과 오프닝 재생 중 다음 계열 상태가 지속적으로 변화했다.

```text
cdrom.audioPlayer.currentSector
cdrom.audioPlayer.currentSample
cdrom.audioPlayer.nextSubcodeSector
cdrom.audioPlayer.subcodeSector
cdrom.audioPlayer.subcodePosition
cdrom.audioPlayer.leftSample
cdrom.audioPlayer.rightSample
cdrom.audioPlayer.clockCounter
cdrom.audioPlayer.irqCounter
```

특히 `cdrom.audioPlayer.currentSector`가 프레임 단위로 지속적으로 증가하였다.

예:

```text
frame=6001 currentSector: 189253 -> 189254
frame=6002 currentSector: 189254 -> 189255
frame=6003 currentSector: 189255 -> 189257
...
```

따라서 오프닝 시퀀스의 오디오는 기존 ADPCM 음성과 달리 **Mesen의 `cdrom.audioPlayer` 경로를 사용하는 CD 오디오 재생**으로 판단된다.

---

## 4. 초경량 CD 오디오 감지기 제작

광범위 프로브는 샘플값과 카운터가 매 프레임 변하면서 수만 줄의 로그가 발생했기 때문에, 최종적으로 `cdrom.audioPlayer.currentSector` 하나만 감시하는 경량 Lua를 제작하였다.

파일:

```text
PROBE_OPENING_CD_AUDIO.lua
```

감지 규칙:

```text
currentSector가 증가하기 시작
→ CD AUDIO START

마지막 sector 변화 이후 12프레임 동안 변화 없음
→ CD AUDIO END
```

12프레임은 약 0.2초이며, 짧은 섹터 갱신 지연 때문에 한 오디오가 여러 이벤트로 잘리는 것을 방지하기 위한 grace period다.

출력:

```text
C:\snatcher\dump\opening_cd_audio_events.tsv
```

---

## 5. 실측 결과

실제 Power Cycle 후 오프닝 전체를 재생하여 다음 결과를 얻었다.

```text
CD AUDIO START[1] id=CDDA_0001 frame=975 sector=211853
CD AUDIO END[1] id=CDDA_0001 frame=987 sector=211853 duration=0.200s

CD AUDIO START[2] id=CDDA_0002 frame=1091 sector=211855
CD AUDIO END[2] id=CDDA_0002 frame=1342 sector=212154 duration=4.183s

CD AUDIO START[3] id=CDDA_0003 frame=2218 sector=184016
CD AUDIO END[3] id=CDDA_0003 frame=2230 sector=184016 duration=0.200s

CD AUDIO START[4] id=CDDA_0004 frame=2331 sector=184018
CD AUDIO END[4] id=CDDA_0004 frame=10283 sector=193971 duration=132.533s

CD AUDIO START[5] id=CDDA_0005 frame=10472 sector=193970
CD AUDIO END[5] id=CDDA_0005 frame=10484 sector=193970 duration=0.200s
```

핵심은 다음 구간이다.

```text
START[4]
frame = 2331
sector = 184018

END[4]
frame = 10283
sector = 193971
duration = 132.533 sec
```

즉 **오프닝 본편 CD 오디오가 약 132.5초 동안 하나의 연속된 재생 구간으로 존재한다.**

`START[1]`, `START[3]`, `START[5]`처럼 0.2초만 지속되는 이벤트는 실제 음성 본편이라기보다 CD 오디오 초기화·seek·전환 과정에서 발생하는 짧은 sector 변화일 가능성이 높다.

`START[2]`의 4.183초 구간도 오프닝 본편 이전의 별도 CD 오디오 구간으로 보인다.

---

## 6. 현재 결론

스내처 PCE-CD의 음성 경로는 최소 두 종류가 존재한다.

```text
일반 게임 대사
→ ADPCM
→ cdrom.adpcm.playing 기반 START/END 감지 가능

오프닝 시퀀스 나레이션/오디오
→ CD audioPlayer
→ cdrom.audioPlayer.currentSector 기반 재생 구간 감지 가능
```

따라서 기존 `runtime_text_audit.lua`가 오프닝 나레이션을 못 잡은 것은 버그라기보다 **오디오 재생 경로 자체가 달랐기 때문**이다.

---

## 7. 오프닝 자막 구현 관점에서의 의미

오프닝 CD 오디오는 약 132.5초짜리 하나의 긴 재생 구간으로 확인되었다.

따라서 오프닝 자막을 구현할 때 일반 ADPCM 대사처럼 음성 한 문장마다 START/END 이벤트를 찾을 필요가 없다.

가장 단순한 구조는 다음과 같다.

```text
CD 오디오 본편 START 감지
↓
오프닝 자막 타이머 = 0
↓
미리 작성한 타임코드 테이블에 따라 자막 출력
↓
CD 오디오 END에서 자막 시스템 종료
```

즉 자막 구현에 필요한 후킹 포인트는 사실상 **오프닝 본편 CD 오디오 시작 지점 하나**면 충분할 가능성이 높다.

예:

```text
0.000   첫 번째 나레이션
4.350   두 번째 나레이션
8.920   세 번째 나레이션
...
132.xxx 종료
```

이 방식이면 음성 데이터 자체를 수정하거나 ADPCM 이벤트를 문장별로 추적할 필요가 없다.

---

## 8. 다음 작업 권장

다음 AI는 우선 **`START[4]`에 해당하는 오프닝 본편의 실제 게임 측 재생 명령/BIOS 호출 지점**을 찾는 것이 좋다.

목표는 Mesen 내부 상태값을 감시하는 Lua를 최종 패치에 넣는 것이 아니라, 게임 코드에서 오프닝 CD 오디오를 시작하는 명령을 찾아 **실제 게임 코드 후킹 지점**으로 사용하는 것이다.

권장 순서:

```text
1. frame 2331 부근에서 CD audio 시작 명령 추적
2. 해당 PC / BIOS CD AUDIO 호출 위치 확인
3. 오프닝 본편 sector 184018 시작 여부 확인
4. 그 지점을 오프닝 자막 타이머 시작 훅으로 확정
5. 별도 자막 타임테이블 작성
6. frame 또는 VBlank 기준으로 자막 타이머 증가
7. 132.5초 종료 또는 장면 전환 시 자막 루틴 해제
```

특히 **sector 184018**은 오프닝 본편 시작을 식별하는 매우 좋은 실측 기준값이다.

---

## 9. 건드리지 말아야 할 것

현재 일반 음성 수집은 정상 작동하고 있으므로 `runtime_text_audit.lua`의 ADPCM 수집 부분은 이번 작업 때문에 수정하지 않는 것을 권장한다.

구조는 다음과 같이 유지한다.

```text
runtime_text_audit.lua
→ 정식 일반 플레이 수집기
→ TEXT / UI / ADPCM

PROBE_OPENING_CD_AUDIO.lua
→ 오프닝 CD AUDIO 분석용
→ 최종적으로는 실제 게임 코드 훅 탐색에만 사용
```

---

## 10. 최종 요약

**오프닝 나레이션 누락 원인 확인 완료.**

일반 대사는 ADPCM이지만 오프닝은 `cdrom.audioPlayer`를 사용하는 별도의 CD 오디오 경로다.

오프닝 본편은 실측상:

```text
frame 2331 ~ 10283
sector 184018 ~ 193971
132.533초
```

의 하나의 연속 CD 오디오 구간이다.

따라서 향후 오프닝 자막은 **CD AUDIO 본편 시작 지점 하나를 후킹하여 타이머를 시작하고, 타임코드 테이블로 전체 자막을 출력하는 방식**이 가장 단순하고 안정적인 방향이다.

다음 단계는 `sector 184018`을 시작시키는 실제 게임 코드 위치를 찾는 것이다.
