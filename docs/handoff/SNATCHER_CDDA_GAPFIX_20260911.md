# SNATCHER CD-DA gap fix — 2026-09-11

## 증상

CD-DA 자막은 시작 시각에는 맞지만, 다음 자막이 올 때까지 이전 자막이 계속
남았다. 원인은 중간 `frames`를 CD-DA 렌더러가 무시하고 있었기 때문이다.

## 수정

`build_subtitle_engine_ac_record_poc.py`에 CD-DA 전용 `expire_frames` 경로를
추가했다. 레코드를 다시 만든 뒤 `record + 4/+5`의 16-bit frames를 한 프레임씩
감소시키고, 0이 되면 `ready=$FF (READY_IDLE)`로 바꿔 push를 멈춘다. 다음
스케줄러 due가 `ready=0`을 쓰므로 중간 공백 뒤의 다음 자막은 정상적으로 다시
나온다.

수명 코드는 실제 출하 경로인 RAM 슬롯 렌더러와 ROM 상주 렌더러에 모두 켰다.
ROM 렌더러가 28 B 커져 기존 캐시 루틴과 겹치므로 캐시 루틴을 `$FEAB`로
이동했다. 스케줄러의 시작 시각 표와 자막 팩은 수정하지 않았다.

## 산출물

`build/patch/0.7.6-gapfix/`는 0.7.5의 CUE/오디오 트랙과 새 BIOS를 함께 담은
실행용 폴더다. `README_GAPFIX.txt`의 BIOS를 Mesen에서 선택한다.

정적 검증:

- renderer 396 B, `$FD1F-$FEAA`
- scheduler 697 B, `$ECF9-$EFB1`
- cache 152 B, `$FEAB-$FF42`
- subtitle pack SHA-256 `4B12B53C...09EAF3`
- mini index 744 entries, SHA-256 `7AFE1B00...7DE2D824`
