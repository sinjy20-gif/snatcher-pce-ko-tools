-- SUB 0.2.6 -- reception action-menu cache capture (read-only).
-- Run once without skipping the first scene, open the reception action menu,
-- then stop. Restart Mesen, repeat with skip. Compare the two output TSVs.
local MEM, CPU = emu.memType.pceMemory, emu.memType.cpu
local OUT = string.format('C:/snatcher/dump/sub_0_2_6_ui_cache_%s.tsv', os.date('%Y%m%d_%H%M%S'))
local CACHE, PRIVATE, RENDER = 0x5B80, 0x7FEC, 0x66E5
local f = assert(io.open(OUT, 'w'))
f:write('frame\tseq\tpointer\tsource_hex\tcache_header\tcache_text\tmenu_marker\tmenu_index\tprivate\n')
local frame, seq, pending = 0, 0, {}

local function hex(at, count)
  local t = {}
  for i = 0, count - 1 do t[#t + 1] = string.format('%02X', emu.read(at + i, MEM) or 0) end
  return table.concat(t, ' ')
end
local function source(at)
  local t = {}
  for i = 0, 47 do
    local b = emu.read(at + i, MEM) or 0
    t[#t + 1] = string.format('%02X', b)
    if b == 0xFF then break end
  end
  return table.concat(t, ' ')
end
local function flush(item)
  seq = seq + 1
  f:write(string.format('%d\t%d\t%04X\t%s\t%s\t%s\t%s\t%s\t%s\n',
    frame, seq, item.ptr, item.src, hex(CACHE, 16), hex(CACHE + 0x10, 32),
    hex(CACHE + 0x0C, 4), hex(CACHE + 0x40, 12), hex(PRIVATE, 19)))
  f:flush()
  emu.log(string.format('SUB 0.2.6 UI CAPTURE #%d ptr=$%04X', seq, item.ptr))
end

-- The runtime preloader accepts only $3499/$349A for UI action labels.
-- Capturing at the renderer entry avoids touching cache or source buffers.
emu.addMemoryCallback(function()
  local ptr = (emu.read(0x3471, MEM) or 0) | ((emu.read(0x3472, MEM) or 0) << 8)
  if ptr ~= 0x3499 and ptr ~= 0x349A then return end
  pending[#pending + 1] = {ptr = ptr, src = source(ptr)}
end, emu.callbackType.exec, RENDER, RENDER, emu.cpuType.pce, CPU)

emu.addEventCallback(function()
  frame = frame + 1
  for _, item in ipairs(pending) do flush(item) end
  pending = {}
end, emu.eventType.endFrame)
emu.addEventCallback(function() f:close() end, emu.eventType.scriptEnded)

emu.log('SUB 0.2.6 loaded -- reception UI cache read-only capture')
emu.log('  output: ' .. OUT)
emu.log('  노스킵/스킵 각각 접수처 액션 메뉴를 한 번 열고 Stop')
