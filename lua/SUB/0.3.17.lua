-- SUB 0.3.17 -- build 0.4.6.5 title-sprite + persistent guard audit
-- Load this one file, Power Cycle, and proceed without skipping.

local MEM = emu.memType.pceMemory
local loadOneCalls, guardWrites = 0, 0

emu.addMemoryCallback(function()
  loadOneCalls = loadOneCalls + 1
  if loadOneCalls == 1 then
    emu.log('SUB 0.3.17 BIOS preload START -- first and only transfer expected')
  elseif loadOneCalls == 4 then
    emu.log('SUB 0.3.17 BIOS preload issued all 4 payloads')
  elseif loadOneCalls == 5 then
    emu.log('SUB 0.3.17 ★ FAIL: full AC preload started again')
  end
end, emu.callbackType.exec, 0xFFA1, 0xFFA1, emu.cpuType.pce, MEM)

emu.addMemoryCallback(function(address, value)
  guardWrites = guardWrites + 1
  local ok, s = pcall(emu.getState); s = ok and s or {}
  emu.log(string.format('SUB 0.3.17 GUARD WRITE #%d PC=%04X $%04X=%02X%s',
    guardWrites, s['cpu.pc'] or 0, address, value or 0,
    guardWrites > 1 and ' ★ unexpected after preload' or ''))
end, emu.callbackType.write, 0x1A32, 0x1A32, emu.cpuType.pce, MEM)

dofile('C:/snatcher/lua/SUB/0.3.14.lua')
emu.log('SUB 0.3.17 loaded -- build 0.4.6.5 / title sprite + persistent guard audit')
emu.log('  합격: 처음부터 표시 · preload 4 calls · guard write 1 · 접수처 AC late read 0')
