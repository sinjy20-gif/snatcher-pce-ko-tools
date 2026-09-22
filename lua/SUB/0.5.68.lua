-- SUB 0.5.68 -- BIOS 0.4.6.44 CD-DA state/rearm 원인 read-only trace
-- $7FDF와 CD-DA elapsed의 writer PC, resident 분기를 관찰한다. 메모리 쓰기 없음.

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/sub/cdda_state_writer_0_5_68_' .. STAMP .. '.tsv'
local out = assert(io.open(OUT, 'w'), 'cannot open ' .. OUT)

local STATE, ELAPSED = 0x7FDF, 0x5E1D
local frame = 0
local counts = { state=0, elapsed=0, start=0, entry=0, resident=0 }

local function rb(at) return emu.read(at, MEM) or 0 end
local function pcNow()
  local ok, s = pcall(emu.getState)
  if not ok or type(s) ~= 'table' then return -1 end
  for _, key in ipairs({ 'cpu.pc', 'pc' }) do
    if type(s[key]) == 'number' then return math.floor(s[key]) & 0xFFFF end
  end
  return -1
end
local function elapsed() return rb(ELAPSED) | (rb(ELAPSED + 1) << 8) end
local function emit(event, detail)
  local line = string.format('%d\t%s\tpc=%04X\tstate=%02X\telapsed=%d\ttrack=%02X\tpulse=%02X/%02X\t%s',
    frame, event, pcNow() & 0xFFFF, rb(STATE), elapsed(), rb(0x26F9),
    rb(0x263C), rb(0x2638), detail or '')
  out:write(line .. '\n'); out:flush()
  emu.log('SUB 0.5.68 ' .. line:gsub('\t', ' · '))
end
local function exec(at, event)
  emu.addMemoryCallback(function()
    counts.resident = counts.resident + 1
    emit(event, '')
  end, emu.callbackType.exec, at, at, CPU, MEM)
end

-- 0.8.3 resident: $7F49 base + JSON offsets.
exec(0x7F49, 'RESIDENT_ENTRY')
exec(0x7F77, 'RESIDENT_RESTORE')
exec(0x7F82, 'RESIDENT_RUN')
exec(0x7FBB, 'RESIDENT_COPY_RENDERER')
exec(0xFEC7, 'FEC7_RETURN')

emu.addMemoryCallback(function()
  counts.start = counts.start + 1
  emit('CDDA_START', 'hit=' .. counts.start)
end, emu.callbackType.exec, 0xF79B, 0xF79B, CPU, MEM)

emu.addMemoryCallback(function()
  counts.entry = counts.entry + 1
  if counts.entry <= 16 then emit('ENGINE_ENTRY', 'hit=' .. counts.entry) end
end, emu.callbackType.exec, 0x5B83, 0x5B83, CPU, MEM)

emu.addMemoryCallback(function(address, value)
  counts.state = counts.state + 1
  emit('STATE_WRITE', string.format('write=%02X hit=%d', value or 0, counts.state))
end, emu.callbackType.write, STATE, STATE, CPU, MEM)

emu.addMemoryCallback(function(address, value)
  counts.elapsed = counts.elapsed + 1
  if counts.elapsed <= 24 or (value or 0) == 0 then
    emit(address == ELAPSED and 'ELAPSED_LO_WRITE' or 'ELAPSED_HI_WRITE',
      string.format('write=%02X hit=%d', value or 0, counts.elapsed))
  end
end, emu.callbackType.write, ELAPSED, ELAPSED + 1, CPU, MEM)

emu.addEventCallback(function() frame = frame + 1 end, emu.eventType.endFrame)
emu.addEventCallback(function()
  local line = string.format('# stateWrites=%d elapsedWrites=%d starts=%d entries=%d residentEvents=%d',
    counts.state, counts.elapsed, counts.start, counts.entry, counts.resident)
  out:write(line .. '\n'); out:close(); emu.log('SUB 0.5.68 ' .. line)
end, emu.eventType.scriptEnded)

out:write('frame\tevent\tpc\tstate\telapsed\ttrack\tpulse\tdetail\n')
out:flush()
emu.log('SUB 0.5.68 loaded -- BIOS 0.4.6.44 CD-DA state writer read-only trace')
emu.log('  먼저 로드 후 Power Cycle · 키 입력 없음 · 메모리 쓰기 없음')
emu.log('  결과: ' .. OUT)
