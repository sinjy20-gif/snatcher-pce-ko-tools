-- SUB 0.5.66 -- BIOS 0.4.6.43 CD-DA + ADPCM 통합 경로 read-only 측정
-- 메모리 쓰기/AC 업로드/자막 state 변경 없음. 먼저 로드한 뒤 Power Cycle 한다.

local MEM, AC, CPU = emu.memType.pceMemory, emu.memType.pceArcadeCardRam,
                     emu.cpuType.pce
local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/sub/native_dual_0_5_66_' .. STAMP .. '.tsv'
local out = io.open(OUT, 'w')

local STATE, SLOT, SCHED = 0x7FDF, 0x1F2700, 0x1F2710
local ENGINE_SIG = 0x5DDA                 -- CD-DA timer 첫 opcode $38
local CD_ELAPSED = 0x5E1D                -- 0.4.6.25 state3 engine
local RECORD_PTR = 0x5CB8
local HELPER_CTL = 0x1F1DB4
local PC = {
  adSlot = 0xF3A9, adRoute = 0xF53C,
  cddaCheck = 0xF761, cddaStart = 0xF778,
  adScheduler = 0xF84B, adPart = 0xF913,
}

local frame = 0
local counts = { adSlot=0, adRoute=0, cddaCheck=0, cddaStart=0,
                 adScheduler=0, adPart=0 }
local priorState, priorKind, priorPart = -1, '', -1
local crossed = {}

local function rb(at, kind) return emu.read(at, kind or MEM) or 0 end
local function hex(at, n, kind)
  local t = {}
  for i = 0, n - 1 do t[#t + 1] = string.format('%02X', rb(at + i, kind)) end
  return table.concat(t, '')
end
local function lba()
  return (rb(SLOT + 1, AC) << 16) | (rb(SLOT + 2, AC) << 8) | rb(SLOT + 3, AC)
end
local function cdElapsed() return rb(CD_ELAPSED) | (rb(CD_ELAPSED + 1) << 8) end
local function adElapsed() return rb(SCHED, AC) | (rb(SCHED + 1, AC) << 8) end
local function kind()
  return rb(ENGINE_SIG) == 0x38 and 'CDDA' or 'ADPCM'
end
local function emit(event, detail)
  local line = string.format(
    '%d\t%s\tstate=%02X\tkind=%s\ttrack=%02X\tpulse=%02X/%02X\t' ..
    'slot=%02X/%06X\thelper=%s\t%s', frame, event, rb(STATE), kind(),
    rb(0x26F9), rb(0x263C), rb(0x2638), rb(SLOT, AC), lba(),
    hex(HELPER_CTL, 4, AC), detail or '')
  emu.log('SUB 0.5.66 ' .. line:gsub('\t', ' · '))
  if out then out:write(line .. '\n'); out:flush() end
end
local function hook(name, at, event)
  emu.addMemoryCallback(function()
    counts[name] = counts[name] + 1
    local pulse = rb(0x263C) | rb(0x2638)
    if (name == 'cddaCheck' and (counts[name] <= 3 or pulse ~= 0))
        or (name == 'adScheduler' and counts[name] <= 3)
        or (name ~= 'cddaCheck' and name ~= 'adScheduler') then
      emit(event, '')
    end
  end, emu.callbackType.exec, at, at, CPU, MEM)
end

hook('adSlot', PC.adSlot, 'ADPCM_SLOT_FOUND')
hook('adRoute', PC.adRoute, 'ADPCM_ROUTE_FOUND')
hook('cddaCheck', PC.cddaCheck, 'CDDA_CHECK')
hook('cddaStart', PC.cddaStart, 'CDDA_START')
hook('adScheduler', PC.adScheduler, 'ADPCM_SCHEDULER')
hook('adPart', PC.adPart, 'ADPCM_PART_DUE')

local function summary(tag)
  local line = string.format(
    '%s checks=%d cddaStart=%d adSlot=%d adRoute=%d adSched=%d adPart=%d state=%02X kind=%s',
    tag, counts.cddaCheck, counts.cddaStart, counts.adSlot, counts.adRoute,
    counts.adScheduler, counts.adPart, rb(STATE), kind())
  emu.log('SUB 0.5.66 ★ ' .. line)
  if out then out:write('# ' .. line .. '\n'); out:flush() end
end

emu.addEventCallback(function()
  frame = frame + 1
  local state, nowKind = rb(STATE), kind()
  if state ~= priorState or nowKind ~= priorKind then
    emit('STATE', string.format('record=%s cdElapsed=%d adPart=%d/%d adElapsed=%d',
      hex(RECORD_PTR, 3, MEM), cdElapsed(), rb(SCHED + 2, AC) + 1,
      rb(SCHED + 3, AC), adElapsed()))
    priorState, priorKind = state, nowKind
  end

  if nowKind == 'CDDA' then
    local elapsed = cdElapsed()
    for _, threshold in ipairs({2188, 2435, 2683}) do
      if elapsed >= threshold and not crossed[threshold] then
        crossed[threshold] = true
        emit('CDDA_THRESHOLD_' .. threshold,
          'elapsed=' .. elapsed .. ' record=' .. hex(RECORD_PTR, 3, MEM))
      end
    end
  elseif nowKind == 'ADPCM' and state == 2 then
    local part = rb(SCHED + 2, AC)
    if part ~= priorPart then
      emit('ADPCM_PART_' .. (part + 1),
        string.format('part=%d/%d elapsed=%d', part + 1,
          rb(SCHED + 3, AC), adElapsed()))
      priorPart = part
    end
  end
  if frame % 600 == 0 then summary('f' .. frame) end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  summary('END')
  if out then out:close() end
end, emu.eventType.scriptEnded)

if out then
  out:write('frame\tevent\tstate\tkind\ttrack\tpulse\tslot\thelper\tdetail\n')
else
  emu.log('SUB 0.5.66 WARNING cannot open ' .. OUT)
end
emu.log('SUB 0.5.66 loaded -- BIOS 0.4.6.43 dual-native read-only measurement')
emu.log('  먼저 로드 후 Power Cycle · 키 입력 없음 · 메모리 쓰기 없음')
emu.log('  CD-DA Track17 2188/2435/2683f + ADPCM D000 0/90/180f 분리 측정')
emu.log('  결과: ' .. OUT)
