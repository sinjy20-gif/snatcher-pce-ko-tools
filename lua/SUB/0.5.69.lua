-- SUB 0.5.69 -- BIOS 0.4.6.45 CD-DA active split 자동 판정 (read-only)
-- 메모리 쓰기/AC 업로드/state 변경 없음. 먼저 로드한 뒤 Power Cycle 한다.

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/sub/cdda_active_split_0_5_69_' .. STAMP .. '.tsv'
local out = assert(io.open(OUT, 'w'), 'cannot open ' .. OUT)

local STATE, ELAPSED, SIG = 0x7FDF, 0x5E1D, 0x5DDA
local frame = 0
local counts = { start=0, sentinel=0, run=0, legacyEnd=0, elapsed=0 }
local crossed = {}

local function rb(at) return emu.read(at, MEM) or 0 end
local function elapsed() return rb(ELAPSED) | (rb(ELAPSED + 1) << 8) end
local function pcNow()
  local ok, s = pcall(emu.getState)
  if not ok or type(s) ~= 'table' then return -1 end
  for _, key in ipairs({ 'cpu.pc', 'pc' }) do
    if type(s[key]) == 'number' then return math.floor(s[key]) & 0xFFFF end
  end
  return -1
end
local function emit(event, detail)
  local line = string.format('%d\t%s\tpc=%04X\tstate=%02X\telapsed=%d\tsig=%02X\ttrack=%02X\tpulse=%02X/%02X\t%s',
    frame, event, pcNow() & 0xFFFF, rb(STATE), elapsed(), rb(SIG), rb(0x26F9),
    rb(0x263C), rb(0x2638), detail or '')
  out:write(line .. '\n'); out:flush()
  emu.log('SUB 0.5.69 ' .. line:gsub('\t', ' · '))
end

emu.addMemoryCallback(function()
  counts.start = counts.start + 1
  emit('CDDA_START', 'hit=' .. counts.start)
end, emu.callbackType.exec, 0xF7A3, 0xF7A3, CPU, MEM)

emu.addMemoryCallback(function()
  counts.sentinel = counts.sentinel + 1
  if counts.sentinel <= 5 or counts.sentinel % 600 == 0 then
    emit('CDDA_ACTIVE_FC', 'hit=' .. counts.sentinel)
  end
end, emu.callbackType.exec, 0xF383, 0xF383, CPU, MEM)

emu.addMemoryCallback(function()
  counts.run = counts.run + 1
  if counts.run <= 5 or counts.run % 600 == 0 then
    emit('RESIDENT_RUN', 'hit=' .. counts.run)
  end
end, emu.callbackType.exec, 0x7F82, 0x7F82, CPU, MEM)

-- legacy ADPCM active가 CD-DA를 즉시 state 3으로 만들던 정확한 writer.
emu.addMemoryCallback(function(address, value)
  if pcNow() == 0xFF06 and rb(0x26F9) == 0x11 then
    counts.legacyEnd = counts.legacyEnd + 1
    emit('FAIL_LEGACY_END', string.format('write=%02X hit=%d',
      value or 0, counts.legacyEnd))
  end
end, emu.callbackType.write, STATE, STATE, CPU, MEM)

emu.addMemoryCallback(function(address, value)
  if rb(SIG) == 0x38 then
    counts.elapsed = counts.elapsed + 1
    if counts.elapsed <= 12 then
      emit(address == ELAPSED and 'ELAPSED_LO_WRITE' or 'ELAPSED_HI_WRITE',
        string.format('write=%02X hit=%d', value or 0, counts.elapsed))
    end
  end
end, emu.callbackType.write, ELAPSED, ELAPSED + 1, CPU, MEM)

local function summary(tag)
  local verdict = 'WAIT'
  if counts.legacyEnd > 0 then verdict = 'FAIL-LEGACY-END'
  elseif counts.start > 1 then verdict = 'FAIL-REARM'
  elseif crossed[2683] then verdict = 'PASS'
  elseif counts.start == 1 and elapsed() > 0 then verdict = 'TIMER-RUNNING' end
  local line = string.format('%s verdict=%s start=%d sentinel=%d run=%d legacyEnd=%d elapsed=%d',
    tag, verdict, counts.start, counts.sentinel, counts.run, counts.legacyEnd, elapsed())
  emu.log('SUB 0.5.69 ★ ' .. line)
  out:write('# ' .. line .. '\n'); out:flush()
end

emu.addEventCallback(function()
  frame = frame + 1
  if rb(SIG) == 0x38 then
    local now = elapsed()
    for _, threshold in ipairs({2188, 2435, 2683}) do
      if now >= threshold and not crossed[threshold] then
        crossed[threshold] = true
        emit('CDDA_THRESHOLD_' .. threshold, 'elapsed=' .. now)
      end
    end
  end
  if frame % 600 == 0 then summary('f' .. frame) end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  summary('END'); out:close()
end, emu.eventType.scriptEnded)

out:write('frame\tevent\tpc\tstate\telapsed\tsig\ttrack\tpulse\tdetail\n')
out:flush()
emu.log('SUB 0.5.69 loaded -- BIOS 0.4.6.45 CD-DA active split read-only test')
emu.log('  먼저 로드 후 Power Cycle · 키 입력 없음 · 메모리 쓰기 없음')
emu.log('  PASS: start=1, legacyEnd=0, elapsed 2188/2435/2683 도달')
emu.log('  결과: ' .. OUT)
