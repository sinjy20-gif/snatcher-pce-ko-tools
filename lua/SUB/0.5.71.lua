-- SUB 0.5.71 -- BIOS 0.4.6.44 정상 화면 기준선 정밀 측정 (read-only)
-- 메모리/AC/state 쓰기, 렌더링, 키 입력 없음. 먼저 로드한 뒤 Power Cycle 한다.

local MEM, AC, CPU = emu.memType.pceMemory, emu.memType.pceArcadeCardRam,
  emu.cpuType.pce
local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/sub/cdda_baseline_0_5_71_' .. STAMP .. '.tsv'
local out = assert(io.open(OUT, 'w'), 'cannot open ' .. OUT)

local STATE, ELAPSED, SIG = 0x7FDF, 0x5E1D, 0x5DDA
local SLOT = 0x1F2700
local frame, lastState, lastKind = 0, -1, ''
local counts = { start=0, state=0, resident=0, run=0, restore=0,
  engine=0, timer=0, elapsedWrite=0, fec7=0 }

local function rb(at, kind) return emu.read(at, kind or MEM) or 0 end
local function elapsed() return rb(ELAPSED) | (rb(ELAPSED + 1) << 8) end
local function lba()
  return (rb(SLOT + 1, AC) << 16) | (rb(SLOT + 2, AC) << 8) | rb(SLOT + 3, AC)
end
local function kind() return rb(SIG) == 0x38 and 'CDDA' or 'ADPCM' end
local function pcNow()
  local ok, s = pcall(emu.getState)
  if not ok or type(s) ~= 'table' then return -1 end
  for _, key in ipairs({ 'cpu.pc', 'pc' }) do
    if type(s[key]) == 'number' then return math.floor(s[key]) & 0xFFFF end
  end
  return -1
end
local function emit(event, detail)
  local line = string.format(
    '%d\t%s\tpc=%04X\tstate=%02X\tkind=%s\telapsed=%d\ttrack=%02X\tpulse=%02X/%02X\tlba=%06X\thelper=%02X%02X%02X%02X\t%s',
    frame, event, pcNow() & 0xFFFF, rb(STATE), kind(), elapsed(), rb(0x26F9),
    rb(0x263C), rb(0x2638), lba(), rb(0xBE64), rb(0xBE65), rb(0xBE66),
    rb(0xBE67), detail or '')
  out:write(line .. '\n'); out:flush()
  emu.log('SUB 0.5.71 ' .. line:gsub('\t', ' · '))
end
local function exec(at, event, counter, limit)
  emu.addMemoryCallback(function()
    counts[counter] = counts[counter] + 1
    if counts[counter] <= (limit or 8) then emit(event, 'hit=' .. counts[counter]) end
  end, emu.callbackType.exec, at, at, CPU, MEM)
end

exec(0x7F49, 'RESIDENT_ENTRY', 'resident', 12)
exec(0x7F77, 'RESIDENT_RESTORE', 'restore', 12)
exec(0x7F82, 'RESIDENT_RUN', 'run', 12)
exec(0x5B83, 'ENGINE_ENTRY', 'engine', 12)
exec(0x5DDA, 'CDDA_TIMER', 'timer', 12)
exec(0xFEC7, 'FEC7_RETURN', 'fec7', 12)

emu.addMemoryCallback(function()
  counts.start = counts.start + 1
  emit('CDDA_START', 'hit=' .. counts.start)
end, emu.callbackType.exec, 0xF79B, 0xF79B, CPU, MEM)

emu.addMemoryCallback(function(address, value)
  counts.state = counts.state + 1
  emit('STATE_WRITE', string.format('write=%02X hit=%d', value or 0, counts.state))
end, emu.callbackType.write, STATE, STATE, CPU, MEM)

emu.addMemoryCallback(function(address, value)
  counts.elapsedWrite = counts.elapsedWrite + 1
  if counts.elapsedWrite <= 24 then
    emit(address == ELAPSED and 'ELAPSED_LO_WRITE' or 'ELAPSED_HI_WRITE',
      string.format('write=%02X hit=%d', value or 0, counts.elapsedWrite))
  end
end, emu.callbackType.write, ELAPSED, ELAPSED + 1, CPU, MEM)

local function summary(tag)
  local line = string.format(
    '%s start=%d stateWrites=%d resident=%d run=%d restore=%d engine=%d timer=%d elapsedWrites=%d fec7=%d state=%02X kind=%s elapsed=%d',
    tag, counts.start, counts.state, counts.resident, counts.run, counts.restore,
    counts.engine, counts.timer, counts.elapsedWrite, counts.fec7, rb(STATE), kind(),
    elapsed())
  out:write('# ' .. line .. '\n'); out:flush()
  emu.log('SUB 0.5.71 ★ ' .. line)
end

emu.addEventCallback(function()
  frame = frame + 1
  local state, nowKind = rb(STATE), kind()
  if state ~= lastState then
    emit('STATE_OBSERVED', string.format('from=%02X to=%02X', lastState & 0xFF, state))
    lastState = state
  end
  if nowKind ~= lastKind then
    emit('ENGINE_KIND', 'from=' .. lastKind .. ' to=' .. nowKind)
    lastKind = nowKind
  end
  if frame % 600 == 0 then summary('f' .. frame) end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  summary('END'); out:close()
end, emu.eventType.scriptEnded)

out:write('frame\tevent\tpc\tstate\tkind\telapsed\ttrack\tpulse\tlba\thelper\tdetail\n')
out:flush()
emu.log('SUB 0.5.71 loaded -- BIOS 0.4.6.44 normal-screen baseline read-only probe')
emu.log('  먼저 로드 후 Power Cycle · 키 입력/메모리 쓰기 없음')
emu.log('  화면은 육안 확인 · start/state/run/engine/timer/writer는 자동 기록')
emu.log('  결과: ' .. OUT)
