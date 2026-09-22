-- SUB 0.5.111 -- ADPCM native base write-order probe (read-only)
-- 0.4.6.64 Power Cycle 뒤 이 파일 하나만 로드한다.
-- active AC engine / CPU engine / helper control의 base 관련 바이트에 대한
-- write callback만 기록한다. 어떤 메모리에도 쓰지 않고 키 입력도 요구하지 않는다.

local TAG = 'SUB 0.5.111'
local MEM, AC, CPU = emu.memType.pceMemory, emu.memType.pceArcadeCardRam, emu.cpuType.pce
local STATE, SLOT = 0x7FDF, 0x1F2700
local ENGINE_AC, ENGINE_CPU, TEMPLATE = 0x1F1F00, 0x5B80, 0x1FE400
local HELPER_CTL = 0x1F1C00 + 432 + 4
local OFF = {242, 277, 282}
local OUT = 'C:/snatcher/dump/sub/adpcm_base_write_0_5_111.tsv'
local MAX = 180

local frame, logs = 0, 0
local f = assert(io.open(OUT, 'w'), TAG .. ': cannot open ' .. OUT)
f:write('frame\twhere\taddr\tvalue\tpc\tstate\tlba\n')
f:flush()

local function rb(at, kind) return emu.read(at, kind) or 0 end
local function lba()
  return (rb(SLOT + 1, AC) << 16) | (rb(SLOT + 2, AC) << 8) | rb(SLOT + 3, AC)
end
local function pc()
  local s = emu.getState()
  local n = s and (s['cpu.pc'] or s.pc)
  return type(n) == 'number' and math.floor(n) or 0
end
local function report(where, at, value)
  if logs >= MAX then return end
  logs = logs + 1
  local p, st, lb = pc(), rb(STATE, MEM), lba()
  emu.log(string.format('%s f%d %-9s $%06X <- %02X pc=$%04X state=%02X lba=%06X',
    TAG, frame, where, at, value or 0, p, st, lb))
  f:write(string.format('%d\t%s\t%06X\t%02X\t%04X\t%02X\t%06X\n',
    frame, where, at, value or 0, p, st, lb))
  f:flush()
end

local function watch(kind, label, at)
  emu.addMemoryCallback(function(_, value) report(label, at, value) end,
    emu.callbackType.write, at, at, CPU, kind)
end

for i, off in ipairs(OFF) do
  watch(AC, 'AC_ACTIVE_' .. i, ENGINE_AC + off)
  watch(MEM, 'CPU_ACTIVE_' .. i, ENGINE_CPU + off)
  watch(AC, 'AC_TEMPLATE_' .. i, TEMPLATE + off)
end
for i = 0, 3 do watch(AC, 'HELPER_' .. i, HELPER_CTL + i) end
emu.addMemoryCallback(function(_, value) report('STATE', STATE, value) end,
  emu.callbackType.write, STATE, STATE, CPU, MEM)
emu.addEventCallback(function() frame = frame + 1 end, emu.eventType.endFrame)

emu.log(TAG .. ' loaded -- key별 base write-order read-only probe')
emu.log('  active AC/CPU/template/helper + state writes 자동 기록 · 키 입력 없음')
emu.log('  결과: ' .. OUT)
