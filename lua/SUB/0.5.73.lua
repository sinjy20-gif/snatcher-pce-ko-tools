-- SUB 0.5.73 -- BIOS 0.4.6.47 single-owner overlay 자동 판정 (read-only)
-- 먼저 로드한 뒤 Power Cycle. 키 입력/CPU RAM/AC/state 쓰기 없음.

local VERSION = rawget(_G, 'SUB_OVERLAY_PROBE_VERSION') or '0.5.73'
local BIOS_VERSION = rawget(_G, 'SUB_OVERLAY_BIOS_VERSION') or '0.4.6.47'
local TAG = 'SUB ' .. VERSION
local MEM, AC, CPU = emu.memType.pceMemory, emu.memType.pceArcadeCardRam,
  emu.cpuType.pce
local STAMP = os.date('%Y%m%d_%H%M%S')
local FILE_VERSION = VERSION:gsub('%.', '_')
local OUT = 'C:/snatcher/dump/sub/native_overlay_' .. FILE_VERSION .. '_' .. STAMP .. '.tsv'
local out = assert(io.open(OUT, 'w'), 'cannot open ' .. OUT)

local STATE, SIG, CD_ELAPSED = 0x7FDF, 0x5DDA, 0x5E1D
local SLOT, SCHED = 0x1F2700, 0x1F2710
local frame, trackingAD, priorPart = 0, false, -1
local counts = { cddaStart=0, cddaFinish=0, state3=0, adArm=0, adEnd=0,
  gameRecordRead=0, engineEntry=0, stateWrites=0 }
local thresholds, parts = {}, {}
local gameRecord = {}

local function rb(at, kind) return emu.read(at, kind or MEM) or 0 end
local function lba()
  return (rb(SLOT + 1, AC) << 16) | (rb(SLOT + 2, AC) << 8) | rb(SLOT + 3, AC)
end
local function cdElapsed() return rb(CD_ELAPSED) | (rb(CD_ELAPSED + 1) << 8) end
local function pcNow()
  local ok, s = pcall(emu.getState)
  if not ok or type(s) ~= 'table' then return -1 end
  for _, key in ipairs({ 'cpu.pc', 'pc' }) do
    if type(s[key]) == 'number' then return math.floor(s[key]) & 0xFFFF end
  end
  return -1
end
local function head()
  local t = {}
  for i = 0, 7 do t[#t + 1] = string.format('%02X', rb(0x5B80 + i)) end
  return table.concat(t, '')
end
local function emit(event, detail)
  local line = string.format(
    '%d\t%s\tpc=%04X\tstate=%02X\tsig=%02X\ttrack=%02X\tpulse=%02X/%02X\t' ..
    'lba=%06X\tcdElapsed=%d\tpart=%d/%d\thead=%s\t%s',
    frame, event, pcNow() & 0xFFFF, rb(STATE), rb(SIG), rb(0x26F9),
    rb(0x263C), rb(0x2638), lba(), cdElapsed(), rb(SCHED + 2, AC) + 1,
    rb(SCHED + 3, AC), head(), detail or '')
  out:write(line .. '\n'); out:flush()
  emu.log(TAG .. ' ' .. line:gsub('\t', ' · '))
end

local function exec(at, event, counter, limit)
  emu.addMemoryCallback(function()
    counts[counter] = counts[counter] + 1
    if counts[counter] <= (limit or 8) then emit(event, 'hit=' .. counts[counter]) end
  end, emu.callbackType.exec, at, at, CPU, MEM)
end

exec(0xF798, 'CDDA_START', 'cddaStart', 4)
exec(0x5B83, 'ENGINE_ENTRY', 'engineEntry', 8)
emu.addMemoryCallback(function()
  counts.cddaFinish = counts.cddaFinish + 1
  thresholds[2683] = true
  emit('CDDA_FINISH', 'hit=' .. counts.cddaFinish)
end, emu.callbackType.exec, 0x5E16, 0x5E16, CPU, MEM)

emu.addMemoryCallback(function(_address, value)
  counts.stateWrites = counts.stateWrites + 1
  if (value or 0) == 3 then counts.state3 = counts.state3 + 1 end
  if counts.stateWrites <= 24 or (value or 0) == 3 then
    emit('STATE_WRITE', string.format('value=%02X state3=%d', value or 0, counts.state3))
  end
end, emu.callbackType.write, STATE, STATE, CPU, MEM)

-- 정상 .42에서 ACT1 title renderer가 실제로 읽은 게임 레코드 머리다.
emu.addMemoryCallback(function(address, value)
  if rb(0x26F9) == 0x11 then
    counts.gameRecordRead = counts.gameRecordRead + 1
    gameRecord[address - 0x5B80 + 1] = (value or 0) & 0xFF
    if counts.gameRecordRead <= 8 then
      emit('GAME_RECORD_READ', string.format('value=%02X hit=%d', value or 0,
        counts.gameRecordRead))
    end
  end
end, emu.callbackType.read, 0x5B80, 0x5B87, CPU, MEM)

local function summary(tag)
  local cdda = 'WAIT'
  if counts.cddaStart > 1 then cdda = 'FAIL-REARM'
  elseif counts.cddaFinish == 1 and counts.state3 >= 1 then cdda = 'PASS'
  elseif counts.cddaStart == 1 then cdda = 'RUNNING' end
  local ad = 'WAIT'
  if parts[1] and parts[2] and parts[3] and counts.adEnd >= 1 then ad = 'PASS'
  elseif counts.adArm >= 1 then ad = 'RUNNING' end
  local owner = 'WAIT'
  local got = {}
  for i = 1, 8 do got[#got + 1] = string.format('%02X', gameRecord[i] or 0) end
  local gotRecord = table.concat(got, '')
  if #gameRecord >= 8 or counts.gameRecordRead >= 8 then
    owner = gotRecord == '82FFFF013E000082' and 'PASS-82-RECORD' or 'CHECK-' .. gotRecord
  end
  local line = string.format(
    '%s CDDA=%s start=%d finish=%d state3=%d thresholds=%s%s%s ADPCM=%s parts=%s%s%s owner=%s',
    tag, cdda, counts.cddaStart, counts.cddaFinish, counts.state3,
    thresholds[2188] and '1' or '-', thresholds[2435] and '2' or '-',
    thresholds[2683] and '3' or '-', ad, parts[1] and '1' or '-',
    parts[2] and '2' or '-', parts[3] and '3' or '-', owner)
  out:write('# ' .. line .. '\n'); out:flush()
  emu.log(TAG .. ' ★ ' .. line)
end

emu.addEventCallback(function()
  frame = frame + 1
  if rb(SIG) == 0x38 and rb(STATE) == 2 then
    local now = cdElapsed()
    for _, threshold in ipairs({ 2188, 2435, 2683 }) do
      if now >= threshold and not thresholds[threshold] then
        thresholds[threshold] = true
        emit('CDDA_THRESHOLD_' .. threshold, 'elapsed=' .. now)
      end
    end
  end

  local state, nowLba = rb(STATE), lba()
  local part, count = rb(SCHED + 2, AC), rb(SCHED + 3, AC)
  if state == 2 and nowLba == 0x003083 and not trackingAD then
    trackingAD, priorPart = true, part
    counts.adArm = counts.adArm + 1; parts[part + 1] = true
    emit('ADPCM_ARM', 'count=' .. count)
  elseif trackingAD and state == 2 and part ~= priorPart then
    priorPart = part; parts[part + 1] = true
    emit('ADPCM_PART_' .. (part + 1), 'count=' .. count)
  elseif trackingAD and state ~= 2 then
    trackingAD = false; counts.adEnd = counts.adEnd + 1
    emit('ADPCM_END', 'final=' .. (priorPart + 1) .. '/' .. count)
  end
  if frame % 600 == 0 then summary('f' .. frame) end
end, emu.eventType.endFrame)

emu.addEventCallback(function() summary('END'); out:close() end,
  emu.eventType.scriptEnded)

out:write('frame\tevent\tpc\tstate\tsig\ttrack\tpulse\tlba\tcdElapsed\tpart\thead\tdetail\n')
out:flush()
emu.log(TAG .. ' loaded -- BIOS ' .. BIOS_VERSION .. ' single-owner overlay read-only test')
emu.log('  먼저 로드 후 Power Cycle · 키 입력/메모리/AC/state 쓰기 없음')
emu.log('  ACT1 무손상 + CD-DA 1/2/3/반납 + ADPCM D000 1/2/3/반납 자동 기록')
emu.log('  결과: ' .. OUT)
