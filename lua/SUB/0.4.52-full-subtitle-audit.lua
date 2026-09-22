-- SUB 0.4.52-full-subtitle-audit -- 전체 자막 전수 검증판
--
-- 실제 정본 팩 902키 / 1,950조각을 전부 연결한다.
-- KEY/MISS/조각전환/와이프를 TSV에 남겨 문제가 난 음성을 바로 특정한다.
-- Power Cycle 뒤 다른 SUB Lua 없이 이 파일 하나만 실행할 것.

local VERSION = '0.4.52b-full-subtitle-audit'
local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/sub_0_4_52_full_audit_' .. STAMP .. '.tsv'
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

-- 0.4.48이 이 함수를 안쪽 realLog로 보존하므로, 그 아래 0.4.31의
-- KEY/MISS와 allocator/wipe 로그가 모두 여기까지 돌아온다.
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
      end
    end
  end
  originalLog(text)
end

SUB_RUNTIME_MINI_COUNT = 11
SUB_VOICE_AUDIT = true
SUB_VOICE_SUPPRESS_LEGACY_GATE = true
dofile('C:/snatcher/lua/SUB/0.4.48-fragment-wipe.lua')
SUB_RUNTIME_MINI_COUNT = nil
SUB_VOICE_AUDIT = nil
SUB_VOICE_SUPPRESS_LEGACY_GATE = nil

emu.addEventCallback(function()
  frame = frame + 1
  emu.drawString(4, 56,
    string.format('FULL SUB 902/1950  OK:%d MISS:%d  %s %d/%d',
      okCount, missCount, currentKey, currentPart, currentParts),
    0x40FF40, 0x000000)
end, emu.eventType.endFrame)

originalLog('SUB ' .. VERSION .. ' loaded -- FULL 902 keys / 1,950 fragments')
originalLog('  allocator는 KEY 일치 뒤에만 무장 · MISS/효과음 완전 무개입')
originalLog('  MISS 동안 legacy E6800 gate만 임시 차단 · $FF0F에서 원값 복원')
originalLog('  문제 식별 TSV: ' .. OUT)
originalLog('  키 대조표: C:/snatcher/build/cutscene_subs/subtitle_runtime_key_map.tsv')
originalLog('  Power Cycle 뒤 이 파일 하나만 실행')
