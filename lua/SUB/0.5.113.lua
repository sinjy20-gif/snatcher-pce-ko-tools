-- SUB 0.5.113 -- ADPCM_003143_FFFF_0E (LBA $003123) 4조각 native scheduler probe
-- 0.4.6.65 Power Cycle 뒤 이 파일 하나만 로드한다. read-only / 키 입력 없음.

local TAG = 'SUB 0.5.113'
local MEM, AC = emu.memType.pceMemory, emu.memType.pceArcadeCardRam
local STATE, SLOT, SCHED = 0x7FDF, 0x1F2700, 0x1F2710
local TARGET = 0x003123
local OUT = 'C:/snatcher/dump/sub/adpcm_003143_scheduler_0_5_113.tsv'
local frame, active, priorPart = 0, false, -1
local f = assert(io.open(OUT, 'w'), TAG .. ': cannot open output')
f:write('frame\tevent\tpart\tcount\telapsed\n'); f:flush()

local function rb(at, kind) return emu.read(at, kind) or 0 end
local function lba()
  return (rb(SLOT + 1, AC) << 16) | (rb(SLOT + 2, AC) << 8) | rb(SLOT + 3, AC)
end
local function elapsed() return rb(SCHED, AC) | (rb(SCHED + 1, AC) << 8) end
local function emit(event, part, count)
  emu.log(string.format('%s %s f%d part %d/%d elapsed %d', TAG, event, frame, part, count, elapsed()))
  f:write(string.format('%d\t%s\t%d\t%d\t%d\n', frame, event, part, count, elapsed())); f:flush()
end

emu.addEventCallback(function()
  frame = frame + 1
  local state, part, count = rb(STATE, MEM), rb(SCHED + 2, AC), rb(SCHED + 3, AC)
  if state == 2 and not active and lba() == TARGET then
    active, priorPart = true, part
    emit('ARM', part + 1, count)
  elseif active and state == 2 and part ~= priorPart then
    priorPart = part
    emit('PART', part + 1, count)
  elseif active and state ~= 2 then
    emit('END', priorPart + 1, count)
    active, priorPart = false, -1
  end
end, emu.eventType.endFrame)

emu.log(TAG .. ' loaded -- LBA $003123 · 4조각 기대 · scheduler read-only')
emu.log('  기대: ARM 1/4 -> PART 2/4 -> PART 3/4 -> PART 4/4 -> END')
emu.log('  결과: ' .. OUT)
