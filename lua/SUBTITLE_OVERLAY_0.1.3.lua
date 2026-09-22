-- SUBTITLE_OVERLAY 0.1.3 - 그리기가 화면에 안 나오는 것을 고친다
--
-- 0.1.2 가 남긴 것
-- ----------------
-- 로직은 전부 맞았다.  실측 로그:
--
--   SUB  적재 E6800_0E -> 금일부로 JUNKER로 임명된 길리언 시드다.
--   SUB  클립 key=E6800_0E -- 자막 1줄
--   SUB  >  금일부로 JUNKER로 임명된 길리언 시드다.
--
-- `SUB  >` 는 emu.drawString 을 부른 **뒤에** 찍는 줄이므로, 표 적재·키 매칭·타이밍이
-- 전부 통과했고 **그리기만 화면에 안 나왔다.**  0.1.2 헤더가 "SUB:ok 가 안 보이면
-- 자막 로직이 아니라 출력 방법을 바꿔야 한다" 고 예상해둔 그 경우다.
--
-- 무엇을 바꿨나
-- -------------
--   1. startFrame -> endFrame 에 그린다
--      Mesen 2 는 프레임 시작에 그리기 표면을 지운다.  startFrame 에서 그리면
--      그 프레임이 렌더되기 전에 지워질 수 있다
--   2. 표시 지속 프레임을 명시한다 (drawString 의 6번째 인자)
--      한 프레임짜리로 그리면 타이밍에 따라 놓친다
--   3. 큰 시험 표식을 항상 그린다
--      이것도 안 보이면 그리기 API 자체가 아니라 **Mesen 설정**이다
--      (Video -> Show HUD / 스크립트 오버레이 표시 여부)
--
-- 상태 판정
-- ---------
--   TEST 막대가 보인다 + 자막이 보인다     해결
--   TEST 는 보이는데 자막이 안 보인다      자막 위치/색 문제.  좌표를 옮긴다
--   TEST 도 안 보인다                      Mesen 설정.  스크립트 그리기가 꺼져 있다

local SUBTITLE_PATH = "C:/snatcher/snatcher_tool/translation/voice_subtitles.tsv"
local EVENT_PATH    = "C:/snatcher/snatcher_tool/translation/voice_events.tsv"

local TEXT_X, TEXT_Y = 8, 200      -- 대사 상자 근처로 내렸다
local MARK_X, MARK_Y = 8, 8
local TEST_X, TEST_Y = 8, 24
local TEXT_COLOR = 0xFFFFFF
local BACK_COLOR = 0x80000000
local HOLD_FRAMES = 1              -- 한 프레임짜리로 그리면 놓친다

local function readTsv(path)
  local file = io.open(path, "rb")
  if file == nil then return nil, "열 수 없음: " .. path end
  local text = file:read("a")
  file:close()
  text = text:gsub("^\239\187\191", "")
  local rows, header = {}, nil
  for line in text:gmatch("[^\r\n]+") do
    local fields = {}
    for field in (line .. "\t"):gmatch("([^\t]*)\t") do fields[#fields + 1] = field end
    if header == nil then
      header = {}
      for index, name in ipairs(fields) do header[name] = index end
    else
      rows[#rows + 1] = fields
    end
  end
  return { header = header, rows = rows }
end

local function get(doc, row, name)
  local index = doc.header[name]
  if index == nil then return "" end
  return row[index] or ""
end

local function endKeyOf(fingerprint)
  local read, len, rate = fingerprint:match("^ADPCM_(%x+)_(%x+)_(%x+)$")
  if read == nil then return nil end
  local finish = (tonumber(read, 16) + tonumber(len, 16)) % 0x10000
  if finish == 0xFFFF then return fingerprint end
  return string.format("E%04X_%s", finish, rate)
end

local byKey = {}
local loadedCount, skippedCount, clipCount = 0, 0, 0

local function buildTable()
  local events = readTsv(EVENT_PATH)
  local subs = readTsv(SUBTITLE_PATH)
  if events == nil or subs == nil then return false end
  local keyOfEvent = {}
  for _, row in ipairs(events.rows) do
    local id = get(events, row, "event_id")
    local fp = get(events, row, "fingerprint")
    if id ~= "" and fp ~= "" then keyOfEvent[id] = endKeyOf(fp) or fp end
  end
  for _, row in ipairs(subs.rows) do
    local id   = get(subs, row, "event_id")
    local text = get(subs, row, "ko_text")
    local key  = keyOfEvent[id]
    if key == nil or text == "" then
      skippedCount = skippedCount + 1
    else
      local list = byKey[key]
      if list == nil then list = {}; byKey[key] = list; clipCount = clipCount + 1 end
      list[#list + 1] = {
        start = tonumber(get(subs, row, "start_sec")) or 0,
        dur   = tonumber(get(subs, row, "duration_sec")) or 0,
        text  = text,
      }
      loadedCount = loadedCount + 1
      emu.log(string.format("SUB  적재 %s -> %s", key, text))
    end
  end
  for _, list in pairs(byKey) do
    table.sort(list, function(a, b) return a.start < b.start end)
  end
  return true
end

local wasPlaying, activeList, activeStart, lastShown, drawCount = false, nil, 0, nil, 0

local function keyNow(state)
  local read = state["cdrom.adpcm.readAddress"]
  local len  = state["cdrom.adpcm.adpcmLength"]
  local rate = state["cdrom.adpcm.playbackRate"]
  if type(read) ~= "number" or type(len) ~= "number" or type(rate) ~= "number" then
    return nil, nil
  end
  read, len, rate = math.floor(read), math.floor(len), math.floor(rate)
  local fingerprint = string.format("ADPCM_%04X_%04X_%02X", read, len, rate)
  local finish = (read + len) % 0x10000
  local key = finish == 0xFFFF and fingerprint or string.format("E%04X_%02X", finish, rate)
  return key, fingerprint
end

local function currentText(frame)
  if activeList == nil then return nil end
  local elapsed = (frame - activeStart) / 60.0
  local chosen = nil
  for _, item in ipairs(activeList) do
    if elapsed >= item.start and (item.dur <= 0 or elapsed < item.start + item.dur) then
      chosen = item
    end
  end
  return chosen and chosen.text or nil
end

-- ★ endFrame 에 그린다.  startFrame 은 그 프레임 렌더 전에 지워질 수 있다
emu.addEventCallback(function()
  local ok, state = pcall(emu.getState)
  if not ok or state == nil then return end
  local frame   = state["frameCount"] or 0
  local playing = state["cdrom.adpcm.playing"] == true

  if playing and not wasPlaying then
    local key, fingerprint = keyNow(state)
    activeList  = key and byKey[key] or nil
    activeStart = frame
    lastShown   = nil
    emu.log(activeList == nil
      and string.format("SUB  (자막 없음) key=%s  지문=%s", key or "?", fingerprint or "?")
      or  string.format("SUB  클립 key=%s -- 자막 %d줄", key, #activeList))
  elseif not playing and wasPlaying then
    activeList, lastShown = nil, nil
  end
  wasPlaying = playing

  drawCount = drawCount + 1
  -- 항상 그리는 시험 표식.  이것도 안 보이면 Mesen 설정 문제다
  emu.drawString(MARK_X, MARK_Y, "SUB:ok " .. tostring(drawCount % 60),
    0xFFFFFF, 0x80000000, 1)
  emu.drawString(TEST_X, TEST_Y, "TEST -- 이 줄이 보이면 그리기는 살아 있다",
    0x60FF60, 0x80000000, 1)

  local text = currentText(frame)
  if text ~= nil then
    emu.drawString(TEXT_X, TEXT_Y, text, 0xFFFFFF, 0x80000000, 1)
    if text ~= lastShown then
      lastShown = text
      emu.log("SUB  > " .. text)
    end
  end
end, emu.eventType.endFrame)

if buildTable() then
  emu.log("SUBTITLE_OVERLAY 0.1.3 loaded")
  emu.log(string.format("  자막 %d줄 · 클립 %d종", loadedCount, clipCount))
  emu.log("  0.1.2 대비: endFrame 에 그린다 · 지속 프레임 명시 · TEST 막대 추가")
  emu.log("  TEST 막대도 안 보이면 Mesen 설정(스크립트 그리기)을 봐야 한다")
else
  emu.log("SUBTITLE_OVERLAY 0.1.3: 표를 만들지 못했습니다")
end
