-- SUB 0.3.24 -- reception composite-pattern repair POC.
-- Exact clean skip-route image for VRAM $2C00-$2DFF (pattern $00B0/$00B2
-- shared 32x32 block).  Apply after the reception renderer finishes.

local MEM  = emu.memType.pceMemory
local VRAM = emu.memType.pceVideoRam
local CPU  = emu.memType.cpu
local armed, done = false, false

-- The clean block is mostly transparent.  Its nonzero bytes form the action
-- menu border: twelve $FFFF row heads and $80 in the first three row groups.
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
end, emu.callbackType.exec, 0x66E5, 0x66E5, emu.cpuType.pce, CPU)

emu.addEventCallback(function()
  if not armed or done then return end
  done = true
  local changed = 0
  for i = 0, 511 do
    if (emu.read(0x2C00 + i, VRAM) or 0) ~= CLEAN[i + 1] then changed = changed + 1 end
    emu.write(0x2C00 + i, CLEAN[i + 1], VRAM)
  end
  emu.log(string.format('SUB 0.3.24 REPAIR PASS: VRAM $2C00-$2DFF · changed=%d/512 B', changed))
  emu.log('  위/아래 접수처 액션 메뉴 글자가 모두 정상인지 확인할 것')
end, emu.eventType.endFrame)

emu.log('SUB 0.3.24 loaded -- reception composite-pattern repair POC')
emu.log('  액션 메뉴를 열거나 커서를 움직이면 한 번 복원한다')
