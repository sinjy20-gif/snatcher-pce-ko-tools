-- SUB 0.5.98 -- BIOS 0.4.6.48 CD-DA 정상 종료 + 중간 스킵 완성 POC
--
-- 0.5.77의 검증된 정상 종료 보정을 포함한다.
--   정상 종료: 복원 직전 백업을 현재 VRAM으로 갱신 -> 새 화면을 낡은 백업으로 덮지 않음
--
-- 0.5.97에서 확정된 중간 스킵 경로를 추가한다.
--   CD audio sector가 재생 중 멈추고 state=2이면 state=3을 요청한다.
--   중간 스킵: 백업을 갱신하지 않고 시작 때 저장한 원본을 즉시 복원 -> 자막 제거
--
-- 자막 시작 전 스킵은 state=0이라 아무 일도 하지 않는다.
-- ADPCM(base != $7900, sig != $38)은 건드리지 않는다.
-- Power Cycle 뒤 이 파일 하나만 로드한다.

local VERSION = '0.5.98'
local TAG = 'SUB ' .. VERSION
local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local VRAM, AC = emu.memType.pceVideoRam, emu.memType.pceArcadeCardRam

local ENTRY      = 0x5B83
local ENTRY_SIG  = { 0xAD, 0x30, 0x5D, 0xD0 }
local STATE      = 0x7FDF
local CDDA_START = 0xF798
local CDDA_SIG   = 0x5DDA
local ELAPSED    = 0x5E1D
local CTL_CMD    = 0x5D30
local CTL_LO     = 0x5D34
local CTL_HI     = 0x5D35

local CDDA_BASE = 0x7900
local AC_BACKUP = 0x1F0400
local TOTAL     = 19 * 128                 -- 2,432 B
local FINISH_AT = 2683
local STALL_FRAMES = 3                     -- CD-DA는 75 sector/s라 정상 재생 중 연속 3f 정지하지 않음

local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/sub/cdda_skip_fix_0_5_98_' .. STAMP .. '.tsv'
local out = assert(io.open(OUT, 'w'), 'cannot open ' .. OUT)
out:write('frame\tevent\tstate\tsig\telapsed\tsector\tbase\tcmd\tdetail\n')
out:flush()

local frame = 0
local cddaArmed = false
local lastState = 0
local lastSector = nil
local sectorWasMoving = false
local stillFrames = 0
local cancelPending = false
local cancelIssued = false
local cancelFrame = -1
local normalRefreshes = 0
local earlyRestores = 0
local ignoredAdpcm = 0

local function rb(at, kind)
  return emu.read(at, kind or MEM) or 0
end

local function elapsed()
  return rb(ELAPSED) | (rb(ELAPSED + 1) << 8)
end

local function helperBase()
  return rb(CTL_LO) | (rb(CTL_HI) << 8)
end

local sectorKey = nil
local function audioSector()
  local ok, s = pcall(emu.getState)
  if not ok or type(s) ~= 'table' then return -1 end
  if sectorKey == nil then
    for _, key in ipairs({
      'cdrom.audioPlayer.currentSector',
      'cdrom.audio.currentSector',
      'cdrom.currentSector'
    }) do
      if s[key] ~= nil then sectorKey = key; break end
    end
    if sectorKey == nil then sectorKey = false end
  end
  local value = sectorKey and s[sectorKey] or nil
  return type(value) == 'number' and math.floor(value) or -1
end

local function isHelper()
  for i = 1, #ENTRY_SIG do
    if rb(ENTRY + i - 1) ~= ENTRY_SIG[i] then return false end
  end
  return true
end

local function emit(event, detail)
  local line = string.format('%d\t%s\t%02X\t%02X\t%d\t%d\t%04X\t%02X\t%s',
    frame, event, lastState & 0xFF, rb(CDDA_SIG), elapsed(), audioSector(),
    helperBase(), rb(CTL_CMD), detail or '')
  out:write(line .. '\n'); out:flush()
  emu.log(TAG .. ' ' .. line:gsub('\t', ' · '))
end

-- 실제 state writer의 값을 보존한다. endFrame에서 MPR이 달라도 판정이 흔들리지 않는다.
emu.addMemoryCallback(function(_address, value)
  lastState = (value or 0) & 0xFF
  if lastState == 0 then
    cancelPending = false
  end
end, emu.callbackType.write, STATE, STATE, CPU, MEM)

emu.addMemoryCallback(function()
  cddaArmed = true
  lastSector = nil
  sectorWasMoving = false
  stillFrames = 0
  cancelPending = false
  cancelIssued = false
  cancelFrame = -1
  emit('CDDA_ARM', '')
end, emu.callbackType.exec, CDDA_START, CDDA_START, CPU, MEM)

-- $5B83은 renderer와 helper가 번갈아 올라온다.
-- renderer 진입이면 중간 스킵 취소를 state=3으로 전달한다.
-- helper 복원이면 정상 종료와 중간 스킵의 백업 처리 방식을 구분한다.
emu.addMemoryCallback(function()
  if not isHelper() then
    if cancelPending and not cancelIssued and cddaArmed
        and lastState == 2 and rb(STATE) == 2 and rb(CDDA_SIG) == 0x38 then
      cancelIssued = true
      cancelPending = false
      cancelFrame = frame
      lastState = 3
      emu.write(STATE, 3, MEM)
      emit('EARLY_CANCEL_STATE3', 'audio stopped; native restore requested')
    end
    return
  end

  if rb(CTL_CMD) == 0 then return end         -- 저장 경로
  local base = helperBase()
  if base ~= CDDA_BASE then
    ignoredAdpcm = ignoredAdpcm + 1
    return
  end

  if cancelIssued then
    -- ★ 중간 스킵: 시작 때 저장한 깨끗한 화면을 그대로 복원한다.
    -- 백업을 현재(자막이 남은) VRAM으로 갱신하면 자막이 지워지지 않는다.
    earlyRestores = earlyRestores + 1
    emit('EARLY_RESTORE', string.format('count=%d lag=%d', earlyRestores,
      cancelFrame >= 0 and (frame - cancelFrame) or -1))
    cancelIssued = false
    cddaArmed = false
    return
  end

  -- ★ 정상 종료: 0.5.77과 동일. 게임이 재생 중 갱신한 화면을 낡은 백업이 덮지 않게 한다.
  local at = base * 2
  local diff = 0
  for i = 0, TOTAL - 1 do
    local now = rb(at + i, VRAM)
    if rb(AC_BACKUP + i, AC) ~= now then diff = diff + 1 end
    emu.write(AC_BACKUP + i, now, AC)
  end
  normalRefreshes = normalRefreshes + 1
  emit('NORMAL_REFRESH', string.format('count=%d diff=%d/%d',
    normalRefreshes, diff, TOTAL))
  cddaArmed = false
end, emu.callbackType.exec, ENTRY, ENTRY, CPU, MEM)

-- Mesen의 CD audio sector는 Lua에서만 쓰는 취소 감지기다.
-- 한 번 실제로 움직인 뒤 3프레임 연속 멈췄을 때만 중간 종료로 인정한다.
emu.addEventCallback(function()
  frame = frame + 1
  if not cddaArmed or lastState ~= 2 or cancelIssued then return end

  local sector = audioSector()
  if sector < 0 then return end

  if lastSector ~= nil and sector ~= lastSector then
    sectorWasMoving = true
    stillFrames = 0
  elseif sectorWasMoving then
    stillFrames = stillFrames + 1
    if stillFrames == STALL_FRAMES and elapsed() < FINISH_AT then
      cancelPending = true
      emit('AUDIO_STOP_DETECTED', 'state=2; early cancel armed')
    end
  end
  lastSector = sector
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  emit('END', string.format('normal=%d early=%d ignoredAdpcm=%d pending=%s issued=%s',
    normalRefreshes, earlyRestores, ignoredAdpcm,
    tostring(cancelPending), tostring(cancelIssued)))
  out:close()
end, emu.eventType.scriptEnded)

emu.log(TAG .. ' loaded -- BIOS 0.4.6.48 CD-DA normal/end + mid-skip fix')
emu.log('  정상 종료는 0.5.77 방식 · 중간 스킵은 즉시 state 3 + 원본 복원')
emu.log('  자막 시작 전 스킵/ADPCM은 무개입 · 키 입력 없음')
emu.log('  결과: ' .. OUT)
