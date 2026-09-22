# Android Beetle PCE 초기 부팅 실패 — 코어 프로브 계획

작성일: 2026-09-09  
상태: 계획만 확정. 코어 수정·NDK 설치·Android `.so` 빌드는 아직 하지 않았다.

## 1. 조사 대상

이 문서의 대상은 **Android RetroArch의 Beetle PCE에서 SNATCHER 한글판이 처음부터
부팅되지 않는 문제**다.

다음 문제와 섞지 않는다.

- 화면 밀림/흔들림 및 오버클럭 효과
- Android에서 ADPCM 다음 자막이 일본어로 나오는 문제
- 소프트 리셋 뒤 AC 재적재 문제

기존 실측은 다음과 같다.

| 환경 | 결과 |
|---|---|
| Android Beetle SuperGrafx | 정상 |
| Android Geargrafx | 정상 |
| Android Beetle PCE Fast | 과거 판에서 정상 확인 기록 있음 |
| PC Beetle PCE | 정상 |
| **Android Beetle PCE** | **초기 부팅 실패** |

`0.4.6.10`에서 AC 일회성 가드를 실제 AC 메모리 확인 방식으로 바꾼 뒤에도
Android Beetle PCE만 실패했다. 따라서 예전 `$1A32` 래치 결함으로 이 증상을
설명할 수 없다. 정본은 `BASELINE_0.4.6.10.md`와
`SNATCHER_AC_GUARD_FIX_2026-08-27.md`다.

## 2. 가능한 조사 방법

RetroArch용 Beetle PCE는 공개된 libretro 코어이므로 Android arm64용 코어에
저부하 로그 프로브를 넣어 별도 `.so`로 빌드할 수 있다.

공식 저장소:

```text
https://github.com/libretro/beetle-pce-libretro
```

2026-09-09에 다음 위치로 shallow clone했다.

```text
C:\snatcher\build\research\beetle-pce-libretro
commit 6d6a35eb802e8ff3479f383fff08975842c7376d
```

Odin2는 arm64 기기이므로 우선 대상 ABI는 `arm64-v8a`다. 결과 코어는 기존
코어를 덮지 않도록 표시 이름과 파일명을 별도로 둔다.

```text
Beetle PCE - SNATCHER BOOT PROBE
mednafen_pce_snatcher_probe_libretro_android.so
```

## 3. 프로브 지점

### Arcade Card

```text
mednafen/hw_misc/arcade_card/arcade_card.cpp
ArcadeCard::Read()   line 41 부근
ArcadeCard::Write()  line 108 부근
```

기록할 값:

- CPU timestamp와 PC
- `$1A00-$1A3F` 레지스터 주소와 값
- 포트 번호
- 계산된 실제 2 MiB AC RAM 주소
- base/offset/increment/control 값
- 읽기/쓰기 누적 바이트와 마지막 진행 시각

### PC Engine I/O와 CD

```text
mednafen/pce/pce.cpp
IORead()/IOWrite()의 CD 및 AC 분기

mednafen/pce/pcecd.cpp
PCECD_Read()/PCECD_Write() 및 CD 명령/데이터 반환 경로
```

기록할 값:

- BIOS가 요청한 CD 명령
- 시작 LBA와 섹터 수
- 섹터별 성공/실패 및 반환 상태
- 같은 읽기의 반복 여부
- 마지막으로 진행한 LBA
- CD IRQ 발생과 해제 시각

### CPU 정지 위치

```text
mednafen/pce/huc6280.h
mednafen/pce/huc6280.cpp
```

현재 코어는 `HuCPU.Timestamp()`를 공개하지만 PC는 바로 꺼낼 공개 함수가 없다.
프로브용 `GetPC()`와 필요하면 `GetMPR()`를 읽기 전용으로 추가한다. 일정 시간 동안
CD/AC 진행이 없으면 PC·MPR·timestamp를 한 번 기록하여 무한 대기 루프를 찾는다.

## 4. 로그 방식

매 접근마다 `printf`나 Android logcat을 호출하면 로깅 자체가 부팅 타이밍을
바꿀 수 있다. 고정 크기 이진 레코드를 메모리 링버퍼에 넣고, 일정 단위 또는
실패 정지 뒤 RetroArch 세이브 디렉터리로 한꺼번에 내보낸다.

권장 출력:

```text
snatcher_boot_probe.bin   원본 저부하 이벤트
snatcher_boot_probe.tsv   종료 때 변환 가능한 요약
```

초기에는 모든 CPU 명령을 기록하지 않는다. 부팅 단계, CD 명령, AC 접근, 진행 정지
표식만 기록한다. 상세 로그는 갈라지는 지점을 찾은 뒤 그 범위에만 추가한다.

## 5. 가장 빠른 비교

정상인 Android Beetle SuperGrafx에도 같은 이벤트 형식의 프로브를 넣고 같은 BIOS,
같은 CHD, 같은 Power Cycle 조건으로 실행한다.

```text
Android Beetle SuperGrafx 정상 로그
Android Beetle PCE 실패 로그
```

두 로그가 처음 갈라지는 사건을 찾는다.

- CD 요청부터 다름: BIOS/CD 상태 또는 코어 초기화 차이
- 같은 LBA에서 PCE만 실패: CD 이미지 읽기/상태 반환 차이
- CD는 같고 AC 주소부터 다름: Arcade Card 포트 구현 또는 ARM64 문제
- 전송 완료 후 멈춤: 완료 상태, IRQ, BIOS 복귀 경로
- PC가 같은 루프에 고정: 그 루프의 탈출 조건을 중심으로 상세 프로브 추가

## 6. 빌드 환경 현황

현재 PC에서 확인한 것:

```text
Android SDK  C:\Users\공영철\AppData\Local\Android\Sdk
Android NDK  없음
GNU make     없음
WSL          설치 안 됨
```

공식 Android NDK 최신 LTS는 조사 시점 기준 r30이며 Windows 패키지는 약 728 MB다.
코어 제작을 재개할 때 NDK와 GNU make 또는 동등한 빌드 구성을 먼저 준비한다.
저장 공간도 먼저 확인한다. 이번 조사에서는 다운로드하거나 설치하지 않았다.

저장소 Makefile에는 별도의 `platform=android` 분기가 없지만 NDK Clang의
`aarch64-linux-android` 컴파일러를 `CC/CXX/AR`에 넘겨 Unix shared-library
타깃으로 크로스컴파일할 수 있다. 기본 출력명은 `mednafen_pce_libretro.so`이며
RetroArch 설치용 이름으로 복사한다.

## 7. 나중에 사용자가 할 일

프로브 코어가 완성된 뒤에만 수행한다.

1. 프로브 코어 ZIP을 Odin2로 복사한다.
2. RetroArch의 `코어 불러오기 → 코어 설치 또는 복원`으로 설치한다.
3. `Beetle PCE - SNATCHER BOOT PROBE`를 선택한다.
4. 실패하던 것과 정확히 같은 CHD와 `syscard3.pce`로 Power Cycle한다.
5. 실패 화면에서 약 10초 기다린 뒤 RetroArch를 정상 종료한다.
6. RetroArch 세이브 디렉터리의 `snatcher_boot_probe.*`를 회수한다.

가능하면 정상인 Beetle SuperGrafx 프로브도 같은 조건으로 한 번 실행하여 비교
로그를 만든다.

## 8. 다음 재개 지점

1. 공식 소스 clone의 commit을 유지한다.
2. Android NDK와 빌드 도구를 준비한다.
3. 코어 표시 이름을 별도 이름으로 바꾼다.
4. 저부하 링버퍼와 save-directory 출력기를 먼저 구현한다.
5. CD/AC/CPU 진행 정지 프로브를 추가한다.
6. arm64 `.so`를 빌드하고 내보낸 심볼과 ABI를 검사한다.
7. RetroArch 설치 ZIP과 짧은 사용 안내를 만든다.
8. Beetle PCE 실패 로그와 Beetle SuperGrafx 정상 로그를 최초 분기점 기준으로 비교한다.

