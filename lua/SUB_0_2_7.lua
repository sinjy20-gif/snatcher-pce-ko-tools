-- SUB 0.2.7 -- reception UI graphics snapshot (read-only).
-- Open the reception action menu once, then Stop.  It writes no emulator memory.
local MEM, CPU, VRAM = emu.memType.pceMemory, emu.memType.cpu, emu.memType.pceVideoRam
local STAMP = os.date('%Y%m%d_%H%M%S')
local DIR = 'C:/snatcher/dump/sub_0_2_7_ui_graphics_' .. STAMP
local INDEX = assert(io.open(DIR .. '.tsv', 'w'))
local RENDER, CACHE = 0x66E5, 0x5B80
local frame, seq, pending = 0, 0, {}

local function readCpu(at)
  return emu.read(at, MEM) or 0
end
local function hexCpu(at, count)
  local t = {}
  for i = 0, count - 1 do t[#t + 1] = string.format('%02X', readCpu(at + i)) end
  return table.concat(t, ' ')
end
local function source(at)
  local t = {}
  for i = 0, 47 do
    local b = readCpu(at + i)
    t[#t + 1] = string.format('%02X', b)
    if b == 0xFF then break end
  end
  return table.concat(t, ' ')
end
local function snapshot(path)
  local f = assert(io.open(path, 'wb'))
  local chunk = {}
  -- Mesen's pceVideoRam is byte-addressed: VDC word $0000 is byte $0000.
  -- 64K words / 128KiB gives the complete pattern, BAT and SATB address space.
  for at = 0, 0x1FFFF do
    chunk[#chunk + 1] = string.char(emu.read(at, VRAM) or 0)
    if #chunk == 2048 then f:write(table.concat(chunk)); chunk = {} end
  end
  if #chunk > 0 then f:write(table.concat(chunk)) end
  f:close()
end
local function flush(item)
  seq = seq + 1
  local stem = string.format('%s_%02d', DIR, seq)
  snapshot(stem .. '.vram.bin')
  INDEX:write(string.format('%d\t%d\t%04X\t%s\t%s\t%s\t%s\n',
    frame, seq, item.ptr, item.src, hexCpu(CACHE, 16),
    hexCpu(CACHE + 0x0C, 4), hexCpu(CACHE + 0x40, 12)))
  INDEX:flush()
  emu.log(string.format('SUB 0.2.7 SNAPSHOT #%d -> %s.vram.bin', seq, stem))
end

INDEX:write('frame\tseq\tpointer\tsource_hex\tcache_header\tmenu_marker\tmenu_index\n')
emu.addMemoryCallback(function()
  local ptr = readCpu(0x3471) | (readCpu(0x3472) << 8)
  if ptr == 0x3499 or ptr == 0x349A then
    pending[#pending + 1] = { ptr = ptr, src = source(ptr) }
  end
end, emu.callbackType.exec, RENDER, RENDER, emu.cpuType.pce, CPU)
emu.addEventCallback(function()
  frame = frame + 1
  for _, item in ipairs(pending) do flush(item) end
  pending = {}
end, emu.eventType.endFrame)
emu.addEventCallback(function() INDEX:close() end, emu.eventType.scriptEnded)

emu.log('SUB 0.2.7 loaded -- reception UI graphics snapshot, read-only')
emu.log('  output index: ' .. DIR .. '.tsv  (each capture has a 128KiB .vram.bin)')
emu.log('  노스킵/스킵 각각 접수처 액션 메뉴를 한 번 열고 Stop')
