-- SUB 0.5.112 -- native base patch가 resident 복사 전에 존재하는지 측정 (read-only)
-- 0.4.6.64 Power Cycle 뒤 이 파일 하나만 로드한다. 키/메모리 쓰기 없음.

local TAG = 'SUB 0.5.112'
local MEM, AC, CPU = emu.memType.pceMemory, emu.memType.pceArcadeCardRam, emu.cpuType.pce
local STATE, SLOT, ENGINE = 0x7FDF, 0x1F2700, 0x1F1F00
local HELPER = 0x1F1C00 + 432 + 4
local DIR_PATH = 'C:/snatcher/build/cutscene_subs/adpcm_native_subtitle_dir_A9722A5F.bin'
local OUT = 'C:/snatcher/dump/sub/adpcm_base_pre_copy_0_5_112.tsv'
local OFF = {242, 277, 282}

local function rb(at, kind) return emu.read(at, kind) or 0 end
local function h3(a, b, c) return string.format('%02X%02X%02X', a, b, c) end
local function lba()
  return (rb(SLOT + 1, AC) << 16) | (rb(SLOT + 2, AC) << 8) | rb(SLOT + 3, AC)
end
local function engineAc()
  return h3(rb(ENGINE + OFF[1], AC), rb(ENGINE + OFF[2], AC), rb(ENGINE + OFF[3], AC))
end
local function engineCpu()
  return h3(rb(0x5B80 + OFF[1], MEM), rb(0x5B80 + OFF[2], MEM), rb(0x5B80 + OFF[3], MEM))
end
local function helper()
  return string.format('%02X%02X%02X%02X', rb(HELPER, AC), rb(HELPER + 1, AC),
    rb(HELPER + 2, AC), rb(HELPER + 3, AC))
end

local raw = assert(io.open(DIR_PATH, 'rb'), TAG .. ': cannot open directory'):read('*a')
assert(#raw % 9 == 0, TAG .. ': directory stride error')
local expect = {}
for at = 1, #raw, 9 do
  local key = (raw:byte(at) << 16) | (raw:byte(at + 1) << 8) | raw:byte(at + 2)
  expect[key] = h3(raw:byte(at + 6), raw:byte(at + 7), raw:byte(at + 8))
end
local f = assert(io.open(OUT, 'w'), TAG .. ': cannot open output')
f:write('frame\tphase\tlba\twant\tac_engine\tcpu_engine\thelper\n'); f:flush()
local frame, count = 0, 0
emu.addEventCallback(function() frame = frame + 1 end, emu.eventType.endFrame)

emu.addMemoryCallback(function(_, value)
  if value ~= 1 and value ~= 2 then return end
  local lb, want = lba(), expect[lba()] or 'NO-DIR'
  local phase = value == 1 and 'PRE_COPY_STATE1' or 'POST_COPY_STATE2'
  local ac, cpu, hp = engineAc(), engineCpu(), helper()
  count = count + 1
  emu.log(string.format('%s #%d f%d %s LBA %06X want=%s ac=%s cpu=%s helper=%s',
    TAG, count, frame, phase, lb, want, ac, cpu, hp))
  f:write(string.format('%d\t%s\t%06X\t%s\t%s\t%s\t%s\n', frame, phase, lb, want, ac, cpu, hp)); f:flush()
end, emu.callbackType.write, STATE, STATE, CPU, MEM)

emu.log(TAG .. ' loaded -- state1 직전 active AC / state2 직후 CPU base 자동 대조')
emu.log('  키 입력 없음 · 결과: ' .. OUT)
