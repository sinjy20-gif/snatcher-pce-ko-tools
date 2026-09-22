-- SUB 0.4.61-full-subtitle-audit -- 전체 902키 전수 검증 기준판
--
-- 검증 완료된 0.60(controller+stage+matched allocator+wipe)을 그대로 실행하고
-- KEY/MISS/PART/allocator/wipe/restore를 TSV에 기록한다.
-- Power Cycle 뒤 다른 SUB Lua 없이 이 파일 하나만 실행할 것.

local VERSION = '0.4.61a-full-subtitle-audit'
local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/sub_0_4_61_full_audit_' .. STAMP .. '.tsv'
local out = assert(io.open(OUT, 'w'))
out:write('frame\ttime\tevent\tkey\tpart\tparts\tdetail\n')
out:flush()

local originalLog = emu.log
local frame, okCount, missCount = 0, 0, 0
local currentKey, currentPart, currentParts = '-', 0, 0

local function clean(text)
  return tostring(text):gsub('[\t\r\n]+', ' ')
end

local function record(event, key, part, parts, detail)
  out:write(string.format('%d\t%s\t%s\t%s\t%d\t%d\t%s\n',
    frame, os.date('%H:%M:%S'), event, key or '-', part or 0, parts or 0,
    clean(detail or '')))
  out:flush()
end

emu.log = function(message)
  local text = tostring(message)
  local keyNo, key, parts = text:match('KEY #(%d+) (%x+) · (%d+)조각')
  if key then
    okCount = tonumber(keyNo) or (okCount + 1)
    currentKey, currentPart, currentParts = key, 1, tonumber(parts) or 1
    record('KEY', key, 1, currentParts, text)
  else
    local missNo, missKey = text:match('MISS #(%d+) (%x+)')
    if missKey then
      missCount = tonumber(missNo) or (missCount + 1)
      record('MISS', missKey, 0, 0, text)
    else
      local part, total = text:match('LUA PART (%d+)/(%d+)')
      if part then
        currentPart, currentParts = tonumber(part), tonumber(total)
        record('PART', currentKey, currentPart, currentParts, text)
      elseif text:find(' WIPE #', 1, true) then
        record('WIPE', currentKey, currentPart, currentParts, text)
      elseif text:find('PATCHED base=', 1, true) then
        record('PATCH', currentKey, currentPart, currentParts, text)
      elseif text:find('armed key=', 1, true) then
        local armKey = text:match('armed key=(%x+)') or currentKey
        record('ARM', armKey, 0, 0, text)
      elseif text:find('★ STAGE REARM #', 1, true) then
        record('STAGE', currentKey, currentPart, currentParts, text)
      elseif text:find(' restore $', 1, true) then
        record('RESTORE', currentKey, currentPart, currentParts, text)
      elseif text:find('게임이 가져갔다', 1, true) then
        record('DROP', currentKey, currentPart, currentParts, text)
      end
    end
  end
  originalLog(text)
end

dofile('C:/snatcher/lua/SUB/0.4.60-full-stack.lua')

emu.addEventCallback(function()
  frame = frame + 1
  emu.drawString(4, 56,
    string.format('FULL 902/1950 OK:%d MISS:%d %s %d/%d',
      okCount, missCount, currentKey, currentPart, currentParts),
    0x40FF40, 0x000000)
end, emu.eventType.endFrame)

originalLog('SUB ' .. VERSION .. ' loaded -- VERIFIED 0.60 STACK + TSV AUDIT')
originalLog('  FULL 902 keys / 1,950 fragments · MISS allocator 무개입')
originalLog('  output: ' .. OUT)
originalLog('  Power Cycle 뒤 이 파일 하나만 실행')
