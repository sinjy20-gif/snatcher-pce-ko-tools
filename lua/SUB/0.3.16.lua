-- SUB 0.3.16 -- build 0.4.6.4 persistent port-3 guard audit
-- Load this one file, Power Cycle, and proceed without skipping.

local MEM = emu.memType.pceMemory
local loadOneCalls, guardWrites = 0, 0

emu.addMemoryCallback(function()
  loadOneCalls = loadOneCalls + 1
  if loadOneCalls == 1 then
    emu.log('SUB 0.3.16 BIOS preload START -- first and only transfer expected')
  elseif loadOneCalls == 4 then
    emu.log('SUB 0.3.16 BIOS preload issued all 4 payloads')
  elseif loadOneCalls == 5 then
    emu.log('SUB 0.3.16 ★ FAIL: full AC preload started again')
  end
end, emu.callbackType.exec, 0xFFAB, 0xFFAB, emu.cpuType.pce, MEM)

emu.addMemoryCallback(function(address, value)
  guardWrites = guardWrites + 1
  local ok, s = pcall(emu.getState); s = ok and s or {}
  emu.log(string.format('SUB 0.3.16 GUARD WRITE #%d PC=%04X $%04X=%02X%s',
    guardWrites, s['cpu.pc'] or 0, address, value or 0,
    guardWrites > 2 and ' ★ unexpected after preload' or ''))
end, emu.callbackType.write, 0x1A32, 0x1A33, emu.cpuType.pce, MEM)

dofile('C:/snatcher/lua/SUB/0.3.14.lua')
emu.log('SUB 0.3.16 loaded -- build 0.4.6.4 / port-3 persistent guard audit')
emu.log('  합격: preload 4 calls · guard writes 2 · 접수처 AC_PAYLOAD late read 0')
