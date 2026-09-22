-- SUB 0.5.101 -- 오프닝 스킵 입력 후보 $2228-$2236 소비 PC 측정 (read-only)
--
-- 0.5.100 정상/스킵 비교에서 스킵에만 이 15 B에 $08 write가 나타났다.
-- 비영 값의 writer/reader PC와 그 주변 코드 바이트를 기록해 실제 스킵 분기를 찾는다.
--
-- BIOS 0.4.6.48 + 이 파일 하나 -> Power Cycle -> 첫 자막 뒤 평소처럼 스킵.
-- 메모리/state/VRAM/AC/입력 쓰기 없음. 전수 exec trace가 없어 속도는 정상에 가깝다.

local VERSION = '0.5.101'
local TAG = 'SUB ' .. VERSION
local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/sub/opening_skip_input_0_5_101_' .. STAMP .. '.tsv'
local out = assert(io.open(OUT, 'w'), 'cannot open ' .. OUT)
out:write('frame\tevent\tpc\taddress\tvalue\ttrack\tstate\telapsed\tcode\tdetail\n')
out:flush()

local INPUT_LO, INPUT_HI = 0x2228, 0x2236
local CD_PLAY_CALLER, SUB_ARM = 0x60E4, 0xF798
local TRACK, STATE, ELAPSED = 0x26F9, 0x7FDF, 0x5E1D

local frame, playCount, armCount = 0, 0, 0
local reads, writes, nonzeroReads, nonzeroWrites = 0, 0, 0, 0
local seen = {}

local function rb(at)
  return emu.read(at, MEM) or 0
end

local function elapsed()
  return rb(ELAPSED) | (rb(ELAPSED + 1) << 8)
end

local function pcNow()
  local ok, s = pcall(emu.getState)
  if not ok or type(s) ~= 'table' then return -1 end
  local value = s['cpu.pc'] or s.pc
  return type(value) == 'number' and (math.floor(value) & 0xFFFF) or -1
end

local function codeAt(pc)
  if pc < 0 then return '' end
  local bytes = {}
  for at = math.max(0, pc - 4), math.min(0xFFFF, pc + 11) do
    bytes[#bytes + 1] = string.format('%02X', rb(at))
  end
  return table.concat(bytes, '')
end

local function emit(event, address, value, detail)
  local pc = pcNow()
  local line = string.format('%d\t%s\t%04X\t%04X\t%02X\t%02X\t%02X\t%d\t%s\t%s',
    frame, event, pc & 0xFFFF, address or 0, (value or 0) & 0xFF,
    rb(TRACK), rb(STATE), elapsed(), codeAt(pc), detail or '')
  out:write(line .. '\n'); out:flush()
  emu.log(TAG .. ' ' .. line:gsub('\t', ' · '))
end

emu.addMemoryCallback(function()
  playCount = playCount + 1
  emit('CD_PLAY_' .. playCount, CD_PLAY_CALLER, 0, 'actual game CD_PLAY caller')
end, emu.callbackType.exec, CD_PLAY_CALLER, CD_PLAY_CALLER, CPU, MEM)

emu.addMemoryCallback(function()
  armCount = armCount + 1
  emit('SUB_ARM_' .. armCount, SUB_ARM, 0, 'subtitle armer')
end, emu.callbackType.exec, SUB_ARM, SUB_ARM, CPU, MEM)

emu.addMemoryCallback(function(address, value)
  reads = reads + 1
  value = (value or 0) & 0xFF
  if value == 0 then return end
  nonzeroReads = nonzeroReads + 1
  local pc = pcNow()
  local key = string.format('R:%04X:%02X:%04X', address, value, pc & 0xFFFF)
  seen[key] = (seen[key] or 0) + 1
  -- 같은 소비 루프는 앞 8회와 이후 64회마다만 콘솔/파일에 남긴다.
  if seen[key] <= 8 or seen[key] % 64 == 0 then
    emit('INPUT_READ', address, value, 'same=' .. seen[key])
  end
end, emu.callbackType.read, INPUT_LO, INPUT_HI, CPU, MEM)

emu.addMemoryCallback(function(address, value)
  writes = writes + 1
  value = (value or 0) & 0xFF
  if value == 0 then return end
  nonzeroWrites = nonzeroWrites + 1
  local pc = pcNow()
  local key = string.format('W:%04X:%02X:%04X', address, value, pc & 0xFFFF)
  seen[key] = (seen[key] or 0) + 1
  if seen[key] <= 8 or seen[key] % 64 == 0 then
    emit('INPUT_WRITE', address, value, 'same=' .. seen[key])
  end
end, emu.callbackType.write, INPUT_LO, INPUT_HI, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  emit('END', 0, 0, string.format(
    'plays=%d arms=%d reads=%d writes=%d nonzeroR=%d nonzeroW=%d',
    playCount, armCount, reads, writes, nonzeroReads, nonzeroWrites))
  out:close()
end, emu.eventType.scriptEnded)

emu.log(TAG .. ' loaded -- opening skip input consumer probe · read-only')
emu.log('  실제 CD_PLAY $60E4 + $2228-$2236 비영 read/write PC만 기록')
emu.log('  Power Cycle -> 첫 자막 뒤 평소 버튼으로 스킵 · 전수 trace 없음')
emu.log('  결과: ' .. OUT)
