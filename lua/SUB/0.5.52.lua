-- SUB 0.5.52 -- 0.4.6.31 native armer 관찰 전용
-- 메모리를 쓰지 않는다. slot/state/mini/selector 변화만 자동 기록한다.

local MEM = emu.memType.pceMemory
local AC = emu.memType.pceArcadeCardRam
local SLOT = 0x1F2700
local MINI = 0x1EF000
local SELECTOR_AC = 0x1F206F
local STATE = 0x7FDF
local ENGINE = 0x5B80

local function rb(at, kind) return emu.read(at, kind) or 0 end
local function hex(at, n, kind)
  local t = {}
  for i = 0, n - 1 do t[#t + 1] = string.format('%02X', rb(at + i, kind)) end
  return table.concat(t, '')
end

local frame, lastStatus, lastState = 0, -1, -1
local targetSeen = false

emu.addEventCallback(function()
  frame = frame + 1
  local status = rb(SLOT, AC)
  local state = rb(STATE, MEM)
  local lba = (rb(SLOT + 1, AC) << 16) | (rb(SLOT + 2, AC) << 8) | rb(SLOT + 3, AC)
  if status ~= lastStatus or state ~= lastState then
    emu.log(string.format(
      'SUB 0.5.52 f%d slot $%02X lba %06X state $%02X cpuMagic %s ready $%02X',
      frame, status, lba, state, hex(ENGINE, 3, MEM), rb(ENGINE + 365, MEM)))
    lastStatus, lastState = status, state
  end
  if lba == 0x003083 and not targetSeen then
    targetSeen = true
    emu.log('SUB 0.5.52 ★ D000 observed')
    emu.log('  slot key   ' .. hex(SLOT + 4, 6, AC))
    emu.log('  mini first ' .. hex(MINI, 13, AC))
    emu.log('  selectorAC ' .. hex(SELECTOR_AC, 9, AC))
    emu.log('  state      ' .. string.format('$%02X', state))
  end
end, emu.eventType.endFrame)

emu.log('SUB 0.5.52 native armer probe loaded -- read only')
emu.log('  D000에서 slot/mini/selector/state 자동 출력')
