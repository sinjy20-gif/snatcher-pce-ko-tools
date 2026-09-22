-- SUB 0.5.88 -- 0.4.6.54 CD-DA 종료 갱신의 읽기 전용 감사
--
-- $7900 CD-DA 복원 한 번만 본다.
--   entry:  현재 VRAM과 기존 AC 백업의 차이
--   status=2: VRAM/AC가 entry의 현재 VRAM과 각각 같은지
--
-- 쓰기는 전혀 하지 않는다. 0.4.6.54 BIOS + CUE에서 이 파일 하나만 로드한다.

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local VRAM, AC = emu.memType.pceVideoRam, emu.memType.pceArcadeCardRam

local ENTRY, STATUS = 0x5B83, 0x5D31
local CMD, BASE_LO, BASE_HI = 0x5D30, 0x5D34, 0x5D35
local AC_BACKUP, TOTAL = 0x1F0400, 2432
local HELPER_SIG = { 0xAD, 0x30, 0x5D, 0xD0 }

local frame, pending, samples, entries, helper_entries = 0, false, 0, 0, 0
local before = {}

local function helper_now()
  for i = 1, #HELPER_SIG do
    -- $5B80-$5B82는 "SUB" magic이고 실제 helper entry는 $5B83이다.
    if (emu.read(ENTRY + i - 1, MEM) or -1) ~= HELPER_SIG[i] then return false end
  end
  return true
end

local function base()
  return (emu.read(BASE_LO, MEM) or 0) | ((emu.read(BASE_HI, MEM) or 0) << 8)
end

local function count_diff(source, reference)
  local n = 0
  for i = 0, TOTAL - 1 do
    if (emu.read(source + i, source == AC_BACKUP and AC or VRAM) or 0) ~= reference[i] then
      n = n + 1
    end
  end
  return n
end

emu.addEventCallback(function() frame = frame + 1 end, emu.eventType.endFrame)

emu.addMemoryCallback(function()
  entries = entries + 1
  local cmd, now_base = emu.read(CMD, MEM) or 0, base()
  local helper = helper_now()
  if helper then
    helper_entries = helper_entries + 1
    emu.log(string.format('SUB 0.5.88 HELPER #%d f=%d cmd=%02X base=$%04X',
                          helper_entries, frame, cmd, now_base))
  elseif entries <= 12 then
    emu.log(string.format(
      'SUB 0.5.88 entry #%d f=%d code=%02X %02X %02X %02X cmd=%02X base=$%04X helper=%s',
      entries, frame,
      emu.read(0x5B80, MEM) or 0, emu.read(0x5B81, MEM) or 0,
      emu.read(0x5B82, MEM) or 0, emu.read(0x5B83, MEM) or 0,
      cmd, now_base, tostring(helper)))
  end
  if pending or not helper or cmd == 0 or now_base ~= 0x7900 then
    return
  end
  local backup_diff = 0
  for i = 0, TOTAL - 1 do
    local value = emu.read(0xF200 + i, VRAM) or 0       -- $7900 word = byte $F200
    before[i] = value
    if (emu.read(AC_BACKUP + i, AC) or 0) ~= value then backup_diff = backup_diff + 1 end
  end
  pending = true
  samples = samples + 1
  emu.log(string.format('SUB 0.5.88 restore entry #%d f=%d: old AC differs %d/%d',
                        samples, frame, backup_diff, TOTAL))
end, emu.callbackType.exec, ENTRY, ENTRY, CPU, MEM)

emu.addMemoryCallback(function(_, value)
  if not pending or (value or 0) ~= 2 then return end
  local vram_diff, ac_diff, vram_ac_diff = 0, 0, 0
  for i = 0, TOTAL - 1 do
    local v = emu.read(0xF200 + i, VRAM) or 0
    local a = emu.read(AC_BACKUP + i, AC) or 0
    if v ~= before[i] then vram_diff = vram_diff + 1 end
    if a ~= before[i] then ac_diff = ac_diff + 1 end
    if v ~= a then vram_ac_diff = vram_ac_diff + 1 end
  end
  emu.log(string.format(
    'SUB 0.5.88 restore done f=%d: VRAM!=entry %d, AC!=entry %d, VRAM!=AC %d / %d',
    frame, vram_diff, ac_diff, vram_ac_diff, TOTAL))
  pending = false
end, emu.callbackType.write, STATUS, STATUS, CPU, MEM)

emu.log('SUB 0.5.88 CD-DA refresh audit armed -- read-only, waits for $7900 restore')
