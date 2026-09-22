-- SUB 0.3.19 -- 0.4.6.6 no-skip/skip reception UI state capture.
-- Read-only.  Load before Power Cycle, enter the reception action menu, Stop.

local MEM  = emu.memType.pceMemory
local AC   = emu.memType.pceArcadeCardRam
local VRAM = emu.memType.pceVideoRam
local CPU  = emu.memType.cpu

local stamp = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/sub_0_3_19_ui_route_' .. stamp .. '.tsv'
local f = assert(io.open(OUT, 'w'))
local frame, seq, closed = 0, 0, false
local pending = {}
local seen = {}

local function byte(at, kind)
  return emu.read(at, kind) or 0
end

local function hex(at, count, kind)
  local t = {}
  for i = 0, count - 1 do
    t[#t + 1] = string.format('%02X', byte(at + i, kind))
  end
  return table.concat(t, ' ')
end

local function source(at)
  local t = {}
  for i = 0, 63 do
    local b = byte(at + i, MEM)
    t[#t + 1] = string.format('%02X', b)
    if b == 0xFF then break end
  end
  return table.concat(t, ' ')
end

local function queue(kind, detail, full)
  pending[#pending + 1] = { kind = kind, detail = detail or '', full = full }
end

local function flush(item)
  seq = seq + 1
  local route = frame >= 10000 and 'NO_SKIP' or 'SKIP'
  local cache = item.full and hex(0x5B80, 0x2C0, MEM) or hex(0x5B80, 0x40, MEM)
  local satb = item.full and hex(0x2000, 0x200, VRAM) or ''
  local sprite_patterns = item.full and hex(0xC000, 0x1000, VRAM) or ''
  f:write(string.format('%d\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n',
    frame, seq, route, item.kind, item.detail,
    hex(0x10000, 0x20, AC), hex(0x7FEC, 0x13, MEM),
    cache, satb, sprite_patterns))
  f:flush()
  emu.log(string.format('SUB 0.3.19 %s %s f=%d', route, item.kind, frame))
end

f:write('frame\tseq\troute\tevent\tdetail\tac_state\tprivate_7fec\tcache_5b80_704\tsatb_512\tvram_c000_4096\n')

local EVENTS = {
  [0x7CEF] = 'TITLE_CACHE',
  [0x73BD] = 'TITLE_CHAIN',
  [0x5E40] = 'KOREAN_LOOKUP',
}
for address, name in pairs(EVENTS) do
  emu.addMemoryCallback(function()
    -- Title callbacks can repeat heavily.  First four of each are enough to
    -- establish ordering without making a huge log.
    seen[name] = (seen[name] or 0) + 1
    if seen[name] <= 4 then
      queue(name, string.format('#%d cache=%s', seen[name], hex(0x5B80, 16, MEM)), false)
    end
  end, emu.callbackType.exec, address, address, emu.cpuType.pce, CPU)
end

emu.addMemoryCallback(function()
  local ptr = byte(0x3471, MEM) | (byte(0x3472, MEM) << 8)
  if ptr ~= 0x3499 and ptr ~= 0x349A then return end
  local detail = string.format('ptr=%04X src=%s', ptr, source(ptr))
  queue('RECEPTION_UI', detail, true)
end, emu.callbackType.exec, 0x66E5, 0x66E5, emu.cpuType.pce, CPU)

emu.addEventCallback(function()
  frame = frame + 1
  for _, item in ipairs(pending) do flush(item) end
  pending = {}
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if closed then return end
  closed = true
  f:close()
  emu.log('SUB 0.3.19 saved: ' .. OUT)
end, emu.eventType.scriptEnded)

emu.log('SUB 0.3.19 loaded -- 0.4.6.6 no-skip/skip UI capture / read-only')
emu.log('  Power Cycle -> 접수처 액션 메뉴 열기 -> Stop')
emu.log('  output: ' .. OUT)
