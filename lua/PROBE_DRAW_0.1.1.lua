-- PROBE 그리기 0.1.1 -- 좌표계를 실측한다
--
-- 0.1.0 이 밝힌 것
-- ---------------------------------------------------------------------------
--     사각형 (4,4) (4,40)     보임      -> 그리기 표면은 살아 있다.  설정 문제 아님
--     "TOP-RIGHT" (150,16)    보임      -> ASCII 는 그려진다
--     (8,16) (8,28) (8,100) (8,180)  안 보임
--     한글 (8,52) (8,64)      안 보임
--
-- 즉 **폰트 문제가 아니라 좌표 문제**다.  x=150 은 보이는데 x=8 이 안 보이고,
-- 보이는 것마저 세로로 줄바꿈됐다 -- 그 자리가 그릴 수 있는 영역의 오른쪽
-- 끝이라는 뜻이다.  drawString 이 쓰는 좌표계가 게임 화면(256x239)과 다르다.
--
-- 이 스크립트가 하는 일
-- ---------------------------------------------------------------------------
-- 격자로 도배해서 **어디부터 어디까지가 실제로 보이는지** 눈으로 재게 한다.
-- 문자는 한 글자만 쓴다 (줄바꿈 때문에 여러 글자는 판정을 흐린다).
--
--     20 px 간격으로 x, y 를 훑으며 그 좌표의 십의 자리를 찍는다
--     화면 네 귀퉁이에 사각형을 찍어 그리기 영역의 경계를 표시한다
--
-- 읽는 법
-- ---------------------------------------------------------------------------
--     보이는 글자들의 좌표를 읽으면 그리기 영역의 원점과 크기가 나온다.
--     예: x=140 부터 보이면 원점이 140 만큼 밀려 있다는 뜻.
--
-- 그리고 getScreenSize / getState 로 Mesen 이 말하는 값도 같이 찍는다.

local reported = false

local function probeApi()
  if reported then return end
  reported = true
  local ok, size = pcall(emu.getScreenSize)
  if ok and size ~= nil then
    local parts = {}
    for k, v in pairs(size) do parts[#parts + 1] = string.format("%s=%s", k, tostring(v)) end
    table.sort(parts)
    emu.log("getScreenSize: " .. table.concat(parts, " "))
  else
    emu.log("getScreenSize: 없음")
  end
end

local function draw()
  -- 그리기 영역의 경계를 사각형으로.  사각형은 0.1.0 에서 보인 것이 확인됐다
  emu.drawRectangle(0, 0, 8, 8, 0x00FF00, true, 2)         -- 좌상
  emu.drawRectangle(248, 0, 8, 8, 0xFF0000, true, 2)       -- 우상 (256 기준)
  emu.drawRectangle(0, 231, 8, 8, 0x0080FF, true, 2)       -- 좌하 (239 기준)
  emu.drawRectangle(248, 231, 8, 8, 0xFFFF00, true, 2)     -- 우하

  -- 20 px 격자.  한 글자만 찍어 줄바꿈을 피한다
  for y = 0, 240, 20 do
    for x = 0, 260, 20 do
      local mark = tostring(math.floor(x / 20) % 10)
      emu.drawString(x, y, mark, 0xFFFFFF, 0xA0000000, 2)
    end
  end

  -- y 축 눈금은 왼쪽 끝에 따로 (x=0 이 보이는지도 같이 본다)
  for y = 0, 240, 20 do
    emu.drawString(0, y, tostring(math.floor(y / 20) % 10), 0x00FF00, 0xA0000000, 2)
  end
end

emu.addEventCallback(draw, emu.eventType.endFrame)
emu.addEventCallback(probeApi, emu.eventType.startFrame)

emu.log("PROBE 그리기 0.1.1 -- 좌표계 실측")
emu.log("  20 px 격자로 도배한다.  보이는 글자의 좌표를 읽으면 원점과 크기가 나온다")
emu.log("  사각형 4 개: 좌상(0,0) 우상(248,0) 좌하(0,231) 우하(248,231)")
emu.log("  네 사각형이 화면 네 귀퉁이에 정확히 오면 좌표계는 256x239 가 맞다")
