-- SUB 0.3.18 -- build 0.4.6.6 pack-flag + persistent guard audit
-- Load this one file, Power Cycle, and proceed without skipping.

local MEM, AC = emu.memType.pceMemory, emu.memType.pceArcadeCardRam
local loadOneCalls, guardWrites, stateReported = 0, 0, false

emu.addMemoryCallback(function()
  loadOneCalls = loadOneCalls + 1
  if loadOneCalls == 1 then
    emu.log('SUB 0.3.18 BIOS preload START -- first and only transfer expected')
  elseif loadOneCalls == 4 then
    emu.log('SUB 0.3.18 BIOS preload issued all 4 payloads')
  elseif loadOneCalls == 5 then
    emu.log('SUB 0.3.18 ★ FAIL: full AC preload started again')
  end
end, emu.callbackType.exec, 0xFFA1, 0xFFA1, emu.cpuType.pce, MEM)

emu.addMemoryCallback(function()
  if loadOneCalls == 4 and not stateReported then
    stateReported = true
    emu.log(string.format('SUB 0.3.18 state flags=%02X %02X %02X (expect 00 01 02)',
      emu.read(0x10003, AC) or 0, emu.read(0x10004, AC) or 0,
      emu.read(0x10005, AC) or 0))
  end
end, emu.callbackType.exec, 0xFF9C, 0xFF9C, emu.cpuType.pce, MEM)

emu.addMemoryCallback(function(address, value)
  guardWrites = guardWrites + 1
  local suffix = (guardWrites == 1 and value == 0x66) and '' or ' ★ unexpected'
  emu.log(string.format('SUB 0.3.18 GUARD WRITE #%d $%04X=%02X%s',
    guardWrites, address, value or 0, suffix))
end, emu.callbackType.write, 0x1A32, 0x1A32, emu.cpuType.pce, MEM)

dofile('C:/snatcher/lua/SUB/0.3.14.lua')
emu.log('SUB 0.3.18 loaded -- build 0.4.6.6 / pack flags 00 01 02 audit')
emu.log('  합격: 한글 표시 · guard 66 1회 · 접수처 045B9E/045D68 재적재 0')
