-- SUB 0.5.67 -- BIOS 0.4.6.44 CD-DA + ADPCM 통합 경로 read-only 측정
-- 메모리 쓰기/AC 업로드/자막 state 변경 없음. 먼저 로드한 뒤 Power Cycle 한다.

local MEM, AC, CPU = emu.memType.pceMemory, emu.memType.pceArcadeCardRam,
                     emu.cpuType.pce
local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/sub/native_dual_0_5_67_' .. STAMP .. '.tsv'
local out = io.open(OUT, 'w')

local SLOT, SCHED = 0x1F2700, 0x1F2710
local ENGINE_SIG = 0x5DDA                 -- CD-DA timer 첫 opcode $38
local CD_ELAPSED = 0x5E1D                -- CD-DA state3 engine elapsed
local RECORD_PTR = 0x5CB8
local HELPER_CTL = 0x1F1DB4
local PC = {
  adSlot = 0xF3A9, adRoute = 0xF53C,
  cddaCheck = 0xF784, cddaStart = 0xF79B,
  adScheduler = 0xF891, adPart = 0xF959,
  engineEntry = 0x5B83,
}

local frame = 0
local counts = { adSlot=0, adRoute=0, cddaCheck=0, cddaStart=0,
                 adScheduler=0, adPart=0, engineEntry=0 }
local priorKind, priorPart = '', -1
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
local function kind() return rb(ENGINE_SIG) == 0x38 and 'CDDA' or 'ADPCM' end
local function emit(event, detail)
  local line = string.format(
    '%d\t%s\tkind=%s\ttrack=%02X\tpulse=%02X/%02X\t' ..
    'slot=%02X/%06X\thelper=%s\t%s', frame, event, kind(),
    rb(0x26F9), rb(0x263C), rb(0x2638), rb(SLOT, AC), lba(),
    hex(HELPER_CTL, 4, AC), detail or '')
  emu.log('SUB 0.5.67 ' .. line:gsub('\t', ' · '))
  if out then out:write(line .. '\n'); out:flush() end
end
local function hook(name, at, event)
  emu.addMemoryCallback(function()
    counts[name] = counts[name] + 1
    local pulse = rb(0x263C) | rb(0x2638)
    if (name == 'cddaCheck' and (counts[name] <= 3 or pulse ~= 0))
        or (name == 'adScheduler' and counts[name] <= 3)
        or (name == 'engineEntry' and counts[name] <= 5)
        or (name ~= 'cddaCheck' and name ~= 'adScheduler' and name ~= 'engineEntry') then
      emit(event, string.format('hit=%d cdElapsed=%d record=%s',
        counts[name], cdElapsed(), hex(RECORD_PTR, 3, MEM)))
    end
  end, emu.callbackType.exec, at, at, CPU, MEM)
end

hook('adSlot', PC.adSlot, 'ADPCM_SLOT_FOUND')
hook('adRoute', PC.adRoute, 'ADPCM_ROUTE_FOUND')
hook('cddaCheck', PC.cddaCheck, 'CDDA_CHECK')
hook('cddaStart', PC.cddaStart, 'CDDA_START')
hook('adScheduler', PC.adScheduler, 'ADPCM_SCHEDULER')
hook('adPart', PC.adPart, 'ADPCM_PART_DUE')
hook('engineEntry', PC.engineEntry, 'ENGINE_ENTRY')

local function summary(tag)
  local verdict = 'WAIT'
  if counts.cddaStart > 1 then verdict = 'FAIL-CDDA-REARM'
  elseif crossed[2683] then verdict = 'CDDA-PASS'
  elseif counts.adPart >= 2 then verdict = 'ADPCM-3PART-SEEN' end
  local line = string.format(
    '%s verdict=%s checks=%d cddaStart=%d engineEntry=%d adSlot=%d adRoute=%d adSched=%d adPart=%d kind=%s',
    tag, verdict, counts.cddaCheck, counts.cddaStart, counts.engineEntry,
    counts.adSlot, counts.adRoute, counts.adScheduler, counts.adPart, kind())
  emu.log('SUB 0.5.67 ★ ' .. line)
  if out then out:write('# ' .. line .. '\n'); out:flush() end
end

emu.addEventCallback(function()
  frame = frame + 1
  local nowKind = kind()
  if nowKind ~= priorKind then
    emit('ENGINE_KIND', string.format('signature=%02X cdElapsed=%d record=%s',
      rb(ENGINE_SIG), cdElapsed(), hex(RECORD_PTR, 3, MEM)))
    priorKind = nowKind
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
  else
    local part = rb(SCHED + 2, AC)
    local count = rb(SCHED + 3, AC)
    if count > 0 and part ~= priorPart then
      emit('ADPCM_PART_' .. (part + 1),
        string.format('part=%d/%d elapsed=%d', part + 1, count, adElapsed()))
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
  out:write('frame\tevent\tkind\ttrack\tpulse\tslot\thelper\tdetail\n')
else
  emu.log('SUB 0.5.67 WARNING cannot open ' .. OUT)
end
emu.log('SUB 0.5.67 loaded -- BIOS 0.4.6.44 dual-native read-only measurement')
emu.log('  먼저 로드 후 Power Cycle · 키 입력 없음 · 메모리 쓰기 없음')
emu.log('  CD-DA Track17 2188/2435/2683f + ADPCM D000 0/90/180f 자동 측정')
emu.log('  결과: ' .. OUT)
