-- PROBE 그리기 0.1.0 -- emu.drawString 이 화면에 나오는가, 한글은 되는가
--
-- 왜
-- ---------------------------------------------------------------------------
-- SUBTITLE_OVERLAY 0.1.2/0.1.3 이 자막을 화면에 못 띄웠다.  로그는 정상이다 --
-- `SUB >` 가 찍히므로 표 적재·키 매칭·타이밍이 다 통과했고 drawString 도 불렀다.
-- 그런데 화면에 아무것도 없다.
--
-- 0.1.3 은 "TEST 막대도 안 보이면 Mesen 설정" 이라는 판정표를 달아 뒀는데,
-- **그 막대가 한글이다** ("TEST -- 이 줄이 보이면 그리기는 살아 있다").
-- Mesen 의 drawString 은 자체 비트맵 폰트를 쓰므로 한글 글리프가 없으면
-- 아무것도 안 그린다.  그러면 진단 막대가 자막과 같은 이유로 사라져서
-- **판정 자체가 성립하지 않는다.**
--
-- 그래서 이 스크립트는 셋을 갈라서 그린다:
--
--     1  ASCII 만        그리기 자체가 되는가
--     2  한글            Mesen 폰트에 한글이 있는가
--     3  도형(사각형)     문자와 무관하게 그리기 표면이 살아 있는가
--
-- 읽는 법
-- ---------------------------------------------------------------------------
--     아무것도 안 보임          Mesen 설정.  스크립트 그리기가 꺼져 있다
--     사각형만 보임             drawString 문제 (폰트/인자)
--     사각형 + ASCII 만 보임    **한글을 못 그린다** -> 자막을 다른 방법으로 그려야 함
--     셋 다 보임                그리기는 정상.  자막은 좌표/지속 문제
--
-- 표시 위치도 일부러 갈라 두었다.  화면 밖으로 나가서 안 보이는 경우를 배제한다.

local function draw()
  -- 3. 도형 -- 문자와 무관
  emu.drawRectangle(4, 4, 60, 10, 0x00FF00, true, 2)
  emu.drawRectangle(4, 40, 60, 10, 0xFF0000, true, 2)

  -- 1. ASCII 만
  emu.drawString(8, 16, "ASCII OK 12345", 0xFFFFFF, 0xC0000000, 2)
  emu.drawString(8, 28, "abcdefg HIJK", 0xFFFF00, 0xC0000000, 2)

  -- 2. 한글
  emu.drawString(8, 52, "한글 테스트", 0xFFFFFF, 0xC0000000, 2)
  emu.drawString(8, 64, "가나다라마", 0x00FFFF, 0xC0000000, 2)

  -- 화면 여러 곳.  잘림/영역 밖을 배제한다
  emu.drawString(8, 100, "MID-LEFT", 0xFFFFFF, 0xC0000000, 2)
  emu.drawString(8, 180, "LOW-LEFT", 0xFFFFFF, 0xC0000000, 2)
  emu.drawString(150, 16, "TOP-RIGHT", 0xFFFFFF, 0xC0000000, 2)
end

-- 두 콜백에 다 걸어 본다.  Mesen 2 는 프레임 시작에 그리기 표면을 지우므로
-- startFrame 에 그린 것은 렌더 전에 사라질 수 있다 -- 어느 쪽이 사는지 본다.
emu.addEventCallback(draw, emu.eventType.endFrame)

local frames = 0
emu.addEventCallback(function()
  frames = frames + 1
  if frames % 120 == 1 then
    emu.log(string.format("그리기 시도 %d 프레임째 -- 화면을 볼 것", frames))
  end
end, emu.eventType.startFrame)

emu.log("PROBE 그리기 0.1.0")
emu.log("  초록 사각형 (4,4) · 빨강 사각형 (4,40)")
emu.log("  ASCII: (8,16) (8,28) (8,100) (8,180) (150,16)")
emu.log("  한글 : (8,52) (8,64)")
emu.log("")
emu.log("  아무것도 안 보임        -> Mesen 설정 (스크립트 그리기)")
emu.log("  사각형만               -> drawString 문제")
emu.log("  사각형 + ASCII 만       -> ★ 한글을 못 그린다")
emu.log("  전부 보임              -> 그리기 정상.  자막은 좌표/지속 문제")
