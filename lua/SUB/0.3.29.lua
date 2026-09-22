-- SUB 0.3.29 -- build 0.4.6.7 reception repair verifier / read-only.
-- Power Cycle, run no-skip, and open the reception action menu once.

local MEM, VRAM, CPU = emu.memType.pceMemory, emu.memType.pceVideoRam, emu.memType.cpu
local armed, done = false, false

local CLEAN = {}
for i = 1, 512 do CLEAN[i] = 0 end
for _, off in ipairs({0,32,64,128,160,192,256,288,320,384,416,448}) do
  CLEAN[off + 1], CLEAN[off + 2] = 0xFF, 0xFF
end
for _, off in ipairs({0,32,64}) do
  for i = 3, 31, 2 do CLEAN[off + i + 1] = 0x80 end
end

emu.addMemoryCallback(function()
  if armed or done then return end
  local ptr = (emu.read(0x3471, MEM) or 0) | ((emu.read(0x3472, MEM) or 0) << 8)
  if ptr ~= 0x3499 and ptr ~= 0x349A then return end
  armed = true
  emu.log(string.format('SUB 0.3.29 reception guard PASS ptr=$%04X', ptr))
end, emu.callbackType.exec, 0x66E5, 0x66E5, emu.cpuType.pce, CPU)

emu.addEventCallback(function()
  if not armed or done then return end
  done = true
  local diff = 0
  for i = 0, 511 do
    if (emu.read(0x2C00 + i, VRAM) or 0) ~= CLEAN[i + 1] then diff = diff + 1 end
  end
  if diff == 0 then
    emu.log('SUB 0.3.29 ★ 0.4.6.7 REPAIR PASS: $2C00-$2DFF byte exact')
  else
    emu.log(string.format('SUB 0.3.29 REPAIR FAIL: mismatch=%d/512 B', diff))
  end
end, emu.eventType.endFrame)

emu.log('SUB 0.3.29 loaded -- 0.4.6.7 reception repair verifier / read-only')
emu.log('  Power Cycle -> 노스킵 -> 접수처 액션 메뉴 열기')
