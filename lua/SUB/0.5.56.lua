-- SUB 0.5.56 -- BIOS 0.4.6.34 AC port1 stride 수정 검증
-- 로드 시 정적 AC 데이터만 올리고, 런타임에는 읽기 전용으로 자동 판정한다.

dofile('C:/snatcher/lua/SUB/0.5.51.lua')

local MEM, AC, CPU = emu.memType.pceMemory, emu.memType.pceArcadeCardRam,
                     emu.cpuType.pce
local SLOT, MINI, SELECTOR_AC = 0x1F2700, 0x1EF000, 0x1F206F
local STATE, ENGINE, SELECTOR_CPU = 0x7FDF, 0x5B80, 0x5B80 + 367
local TARGET, LEGACY_ARM = 0x003083, 0xFEF1
local EXPECT_ENTRY = '00D00E437790010000C3690000'
local EXPECT_SELECTOR = '00D00E437790010000'

local function rb(at, kind) return emu.read(at, kind) or 0 end
local function hex(at, n, kind)
  local t = {}
  for i = 0, n - 1 do t[#t + 1] = string.format('%02X', rb(at + i, kind)) end
  return table.concat(t, '')
end
local function lba()
  return (rb(SLOT + 1, AC) << 16) | (rb(SLOT + 2, AC) << 8) | rb(SLOT + 3, AC)
end
local function yn(v) return v and 'OK' or 'FAIL' end

local frame, lastStatus, lastLba = 0, -1, -1
local before, after, legacy = false, false, 0

local function snapshot(label)
  local mini = hex(MINI, 13, AC)
  local selAC = hex(SELECTOR_AC, 9, AC)
  local selCPU = hex(SELECTOR_CPU, 9, MEM)
  local magic = hex(ENGINE, 3, MEM)
  emu.log(string.format('SUB 0.5.56 ★ %s f%d slot $%02X lba %06X state $%02X',
    label, frame, rb(SLOT, AC), lba(), rb(STATE, MEM)))
  emu.log('  mini         ' .. mini)
  emu.log('  selector AC  ' .. selAC)
  emu.log('  selector CPU ' .. selCPU)
  emu.log('  engine magic ' .. magic)
  if label == 'D000 AFTER' then
    emu.log(string.format('SUB 0.5.56 RESULT mini=%s selectorAC=%s selectorCPU=%s engine=%s',
      yn(mini == EXPECT_ENTRY), yn(selAC == EXPECT_SELECTOR),
      yn(selCPU == EXPECT_SELECTOR), yn(magic == '535542')))
  end
end

emu.addMemoryCallback(function()
  legacy = legacy + 1
  emu.log(string.format(
    'SUB 0.5.56 LEGACY ARM #%d f%d lba %06X · 0.4.6.31 기준선에 남은 구형 gate',
    legacy, frame, lba()))
end, emu.callbackType.exec, LEGACY_ARM, LEGACY_ARM, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  local status, nowLba = rb(SLOT, AC), lba()
  if status ~= lastStatus or nowLba ~= lastLba then
    emu.log(string.format('SUB 0.5.56 f%d slot $%02X lba %06X state $%02X',
      frame, status, nowLba, rb(STATE, MEM)))
    lastStatus, lastLba = status, nowLba
  end
  if nowLba == TARGET and status == 0xA1 and not before then
    before = true; snapshot('D000 BEFORE')
  elseif nowLba == TARGET and status == 0xA2 and not after then
    after = true; snapshot('D000 AFTER')
  end
end, emu.eventType.endFrame)

emu.log('SUB 0.5.56 loaded -- BIOS 0.4.6.34 only')
emu.log('  AC port1 $1A10 검증 · D000에서 자동 PASS/FAIL · 키 입력 불필요')
