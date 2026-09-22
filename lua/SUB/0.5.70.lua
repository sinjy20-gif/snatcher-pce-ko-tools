-- SUB 0.5.70 -- BIOS 0.4.6.46 CD-DA + ADPCM 통합 자동 판정 (read-only)
-- 메모리/AC 쓰기, 자막 렌더링, 키 입력 없음. 먼저 로드한 뒤 Power Cycle 한다.

local MEM, AC, CPU = emu.memType.pceMemory, emu.memType.pceArcadeCardRam,
  emu.cpuType.pce
local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/sub/native_combined_0_5_70_' .. STAMP .. '.tsv'
local out = assert(io.open(OUT, 'w'), 'cannot open ' .. OUT)

local STATE, ELAPSED, SIG = 0x7FDF, 0x5E1D, 0x5DDA
local SLOT, SCHED = 0x1F2700, 0x1F2710
local frame, adpcmTracking, priorPart = 0, false, -1
local counts = { cddaStart=0, activeHook=0, active2=0, legacyEnd=0,
  state=0, adpcmArm=0, adpcmEnd=0 }
local crossed, adpcmParts = {}, {}

local function rb(at, kind) return emu.read(at, kind or MEM) or 0 end
local function elapsed() return rb(ELAPSED) | (rb(ELAPSED + 1) << 8) end
local function lba()
  return (rb(SLOT + 1, AC) << 16) | (rb(SLOT + 2, AC) << 8) | rb(SLOT + 3, AC)
end
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
    '%d\t%s\tpc=%04X\tstate=%02X\telapsed=%d\tsig=%02X\ttrack=%02X\tlba=%06X\tpart=%d/%d\t%s',
    frame, event, pcNow() & 0xFFFF, rb(STATE), elapsed(), rb(SIG), rb(0x26F9),
    lba(), rb(SCHED + 2, AC) + 1, rb(SCHED + 3, AC), detail or '')
  out:write(line .. '\n'); out:flush()
  emu.log('SUB 0.5.70 ' .. line:gsub('\t', ' · '))
end
local function hook(at, event, counter)
  emu.addMemoryCallback(function()
    counts[counter] = counts[counter] + 1
    if counts[counter] <= 8 or counts[counter] % 600 == 0 then
      emit(event, 'hit=' .. counts[counter])
    end
  end, emu.callbackType.exec, at, at, CPU, MEM)
end

hook(0xF7AF, 'CDDA_START', 'cddaStart')
hook(0xFA5A, 'ACTIVE_HOOK_BANK1', 'activeHook')
hook(0xFA6F, 'ACTIVE_RETURNS_2', 'active2')

emu.addMemoryCallback(function(address, value)
  counts.state = counts.state + 1
  local pc = pcNow()
  if pc == 0xFF06 and rb(0x26F9) == 0x11 then
    counts.legacyEnd = counts.legacyEnd + 1
    emit('FAIL_LEGACY_END', string.format('write=%02X hit=%d', value or 0,
      counts.legacyEnd))
  elseif counts.state <= 24 then
    emit('STATE_WRITE', string.format('write=%02X hit=%d', value or 0, counts.state))
  end
end, emu.callbackType.write, STATE, STATE, CPU, MEM)

local function summary(tag)
  local cdda = 'WAIT'
  if counts.legacyEnd > 0 then cdda = 'FAIL-LEGACY-END'
  elseif crossed[2683] then cdda = 'PASS'
  elseif counts.cddaStart > 0 and elapsed() > 0 then cdda = 'TIMER-RUNNING' end
  local adpcm = 'WAIT'
  if adpcmParts[1] and adpcmParts[2] and adpcmParts[3] and counts.adpcmEnd > 0 then
    adpcm = 'PASS'
  elseif counts.adpcmArm > 0 then adpcm = 'RUNNING' end
  local line = string.format(
    '%s CDDA=%s start=%d activeHook=%d active2=%d legacyEnd=%d elapsed=%d ADPCM=%s arms=%d ends=%d parts=%s%s%s',
    tag, cdda, counts.cddaStart, counts.activeHook, counts.active2,
    counts.legacyEnd, elapsed(), adpcm, counts.adpcmArm, counts.adpcmEnd,
    adpcmParts[1] and '1' or '-', adpcmParts[2] and '2' or '-',
    adpcmParts[3] and '3' or '-')
  out:write('# ' .. line .. '\n'); out:flush()
  emu.log('SUB 0.5.70 ★ ' .. line)
end

emu.addEventCallback(function()
  frame = frame + 1
  if rb(SIG) == 0x38 and rb(0x26F9) == 0x11 then
    local now = elapsed()
    for _, threshold in ipairs({ 2188, 2435, 2683 }) do
      if now >= threshold and not crossed[threshold] then
        crossed[threshold] = true
        emit('CDDA_THRESHOLD_' .. threshold, 'elapsed=' .. now)
      end
    end
  end

  local state, nowLba = rb(STATE), lba()
  local part, count = rb(SCHED + 2, AC), rb(SCHED + 3, AC)
  if state == 2 and nowLba == 0x003083 and not adpcmTracking then
    adpcmTracking, priorPart = true, part
    counts.adpcmArm = counts.adpcmArm + 1
    adpcmParts[part + 1] = true
    emit('ADPCM_ARM', 'elapsed=' .. (rb(SCHED, AC) | (rb(SCHED + 1, AC) << 8)))
  elseif adpcmTracking and state == 2 and part ~= priorPart then
    priorPart = part
    adpcmParts[part + 1] = true
    emit('ADPCM_PART_' .. (part + 1), 'count=' .. count)
  elseif adpcmTracking and state ~= 2 then
    adpcmTracking = false
    counts.adpcmEnd = counts.adpcmEnd + 1
    emit('ADPCM_END', 'final=' .. (priorPart + 1) .. '/' .. count)
  end

  if frame % 600 == 0 then summary('f' .. frame) end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  summary('END'); out:close()
end, emu.eventType.scriptEnded)

out:write('frame\tevent\tpc\tstate\telapsed\tsig\ttrack\tlba\tpart\tdetail\n')
out:flush()
emu.log('SUB 0.5.70 loaded -- BIOS 0.4.6.46 combined native read-only test')
emu.log('  먼저 로드 후 Power Cycle · 키 입력/메모리 쓰기 없음')
emu.log('  CD-DA: 2188/2435/2683 · ADPCM D000: 1/2/3 자동 판정')
emu.log('  결과: ' .. OUT)
