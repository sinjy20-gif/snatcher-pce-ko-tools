-- SUB 0.5.54 -- 0.4.6.33 native armer 관찰 전용
-- 메모리를 쓰지 않는다. slot 전환과 D000 arm 완료 뒤의 값을 기록한다.

local MEM = emu.memType.pceMemory
local AC = emu.memType.pceArcadeCardRam
local SLOT = 0x1F2700
local MINI = 0x1EF000
local SELECTOR_AC = 0x1F206F
local STATE = 0x7FDF
local ENGINE = 0x5B80
local SELECTOR_CPU = ENGINE + 367
local TARGET = 0x003083

local function rb(at, kind) return emu.read(at, kind) or 0 end
local function hex(at, n, kind)
  local t = {}
  for i = 0, n - 1 do t[#t + 1] = string.format('%02X', rb(at + i, kind)) end
  return table.concat(t, '')
end

local frame, lastStatus, lastLba = 0, -1, -1
local targetA1, targetA2 = false, false

local function snapshot(label, status, lba, state)
  emu.log(string.format(
    'SUB 0.5.54 %s f%d slot $%02X lba %06X state $%02X cpuMagic %s ready $%02X',
    label, frame, status, lba, state, hex(ENGINE, 3, MEM), rb(ENGINE + 365, MEM)))
  emu.log('  slot key     ' .. hex(SLOT + 4, 6, AC))
  emu.log('  mini first   ' .. hex(MINI, 13, AC))
  emu.log('  selector AC  ' .. hex(SELECTOR_AC, 9, AC))
  emu.log('  selector CPU ' .. hex(SELECTOR_CPU, 9, MEM))
end

emu.addEventCallback(function()
  frame = frame + 1
  local status = rb(SLOT, AC)
  local state = rb(STATE, MEM)
  local lba = (rb(SLOT + 1, AC) << 16) | (rb(SLOT + 2, AC) << 8) | rb(SLOT + 3, AC)

  if status ~= lastStatus or lba ~= lastLba then
    emu.log(string.format('SUB 0.5.54 f%d slot $%02X lba %06X state $%02X',
      frame, status, lba, state))
    lastStatus, lastLba = status, lba
  end

  if lba == TARGET and status == 0xA1 and not targetA1 then
    targetA1 = true
    snapshot('★ D000 BEFORE', status, lba, state)
  elseif lba == TARGET and status == 0xA2 and not targetA2 then
    targetA2 = true
    snapshot('★ D000 AFTER', status, lba, state)
  end
end, emu.eventType.endFrame)

emu.log('SUB 0.5.54 native armer probe loaded -- read only')
emu.log('  BIOS 0.4.6.33 · D000 A1/A2 전후 자동 출력 · 키 입력 불필요')
