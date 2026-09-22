-- SUB 0.3.15 -- build 0.4.6.3 persistent AC one-shot guard audit
-- Load this one file, Power Cycle, and proceed without skipping.

local MEM = emu.memType.pceMemory
local loadOneCalls = 0
emu.addMemoryCallback(function()
  loadOneCalls = loadOneCalls + 1
  if loadOneCalls == 1 then
    emu.log('SUB 0.3.15 BIOS preload START -- first and only transfer expected')
  elseif loadOneCalls == 4 then
    emu.log('SUB 0.3.15 BIOS preload issued all 4 payloads')
  elseif loadOneCalls == 5 then
    emu.log('SUB 0.3.15 ★ FAIL: full AC preload started again')
  end
end, emu.callbackType.exec, 0xFFA5, 0xFFA5, emu.cpuType.pce, MEM)

dofile('C:/snatcher/lua/SUB/0.3.14.lua')
emu.log('SUB 0.3.15 loaded -- build 0.4.6.3 / persistent AC guard audit')
emu.log('  합격: 접수처까지 load_one=4 유지 · AC_PAYLOAD late read 0')
