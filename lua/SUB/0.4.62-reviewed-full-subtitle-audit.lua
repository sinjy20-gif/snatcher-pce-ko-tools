-- SUB 0.4.62-reviewed-full-subtitle-audit
-- 0.4.6.13-reviewed 전수 검증용. 팩의 실제 키/조각 수를 읽어 표시한다.
-- 검증된 0.4.60(controller+stage+matched allocator+wipe) 체인은 그대로 쓴다.
-- Power Cycle 뒤 다른 SUB Lua 없이 이 파일 하나만 실행할 것.

local VERSION = '0.4.62-reviewed-full-subtitle-audit'
local PACK_PATH = 'C:/snatcher/build/cutscene_subs/subtitle_pack.bin'
local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/sub_0_4_62_reviewed_full_audit_' .. STAMP .. '.tsv'

local function readFile(path)
  local f = assert(io.open(path, 'rb'), 'cannot open ' .. path)
  local data = f:read('*a'); f:close(); return data
end

local function u16(data, at)
  return data:byte(at + 1) | (data:byte(at + 2) << 8)
end

local function u32(data, at)
  return u16(data, at) | (u16(data, at + 2) << 16)
end

local pack = readFile(PACK_PATH)
assert(pack:sub(1, 4) == 'SNSB' and u16(pack, 4) == 6,
       'subtitle pack is not SNSB v6')

local fragmentCount, indexAt = u16(pack, 14), u32(pack, 16)
local keys = {}
for n = 0, fragmentCount - 1 do
  local at = indexAt + n * 13
  keys[pack:sub(at + 1, at + 6)] = true
end
local keyCount = 0
for _ in pairs(keys) do keyCount = keyCount + 1 end

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
    string.format('FULL %d/%d OK:%d MISS:%d %s %d/%d',
      keyCount, fragmentCount, okCount, missCount,
      currentKey, currentPart, currentParts),
    0x40FF40, 0x000000)
end, emu.eventType.endFrame)

originalLog(string.format('SUB %s loaded -- VERIFIED 0.60 STACK + TSV AUDIT', VERSION))
originalLog(string.format('  FULL %d keys / %d fragments · pack %d B',
                          keyCount, fragmentCount, #pack))
originalLog('  0.4.6.13-reviewed · MISS allocator 무개입')
originalLog('  output: ' .. OUT)
originalLog('  Power Cycle 뒤 이 파일 하나만 실행')
