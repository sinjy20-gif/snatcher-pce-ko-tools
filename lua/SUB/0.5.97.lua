-- SUB 0.5.97 -- CD-DA 자막 도중 오프닝 스킵 lifecycle 관찰 (read-only)
--
-- 재현 절차
--   1. BIOS 0.4.6.48에서 이 파일만 로드하고 Power Cycle
--   2. 오프닝 첫 자막이 나온 뒤 스킵 버튼을 누른다
--   3. 화면이 바뀐 뒤 로그의 AUDIO_STOP -> STATE/HELPER 순서를 본다
--
-- Lua는 CPU RAM/AC/VRAM/state에 쓰지 않는다. 키 입력도 필요 없다.

local VERSION = '0.5.97'
local TAG = 'SUB ' .. VERSION
local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/sub/cdda_skip_lifecycle_0_5_97_' .. STAMP .. '.tsv'
local out = assert(io.open(OUT, 'w'), 'cannot open ' .. OUT)

local STATE       = 0x7FDF
local TRACK       = 0x26F9
local PULSE_A     = 0x263C
local PULSE_B     = 0x2638
local CDDA_SIG    = 0x5DDA
local ELAPSED     = 0x5E1D
local ENTRY       = 0x5B83
local FINISH      = 0x5E16
local CDDA_START  = 0xF798
local CTL_CMD     = 0x5D30
local CTL_LO      = 0x5D34
local CTL_HI      = 0x5D35
local ENTRY_SIG   = { 0xAD, 0x30, 0x5D, 0xD0 }

local VRAM_FIRST  = 0x7900
local VRAM_LAST   = 0x7DBF

local frame = 0
local lastState = 0
local lastStateFrame = -1
local cddaArmed = false
local audioWasMoving = false
local audioStopped = false
local audioStopFrame = -1
local lastSector = nil
local stillFrames = 0
local helperSave = 0
local helperRestore = 0
local rendererEntry = 0
local bandWrites = 0
local bandWritesAfterStop = 0
local firstPostStopWrite = false
local milestoneSeen = {}

local function rb(at)
  return emu.read(at, MEM) or 0
end

local function elapsed()
  return rb(ELAPSED) | (rb(ELAPSED + 1) << 8)
end

local function base()
  return rb(CTL_LO) | (rb(CTL_HI) << 8)
end

local function pcNow()
  local ok, s = pcall(emu.getState)
  if not ok or type(s) ~= 'table' then return -1 end
  local v = s['cpu.pc'] or s.pc
  return type(v) == 'number' and (math.floor(v) & 0xFFFF) or -1
end

local sectorKey = nil
local function audioSector()
  local ok, s = pcall(emu.getState)
  if not ok or type(s) ~= 'table' then return -1 end
  if sectorKey == nil then
    for _, k in ipairs({
      'cdrom.audioPlayer.currentSector',
      'cdrom.audio.currentSector',
      'cdrom.currentSector'
    }) do
      if s[k] ~= nil then sectorKey = k; break end
    end
    if sectorKey == nil then sectorKey = false end
  end
  local v = sectorKey and s[sectorKey] or nil
  return type(v) == 'number' and math.floor(v) or -1
end

local function isHelper()
  for i = 1, #ENTRY_SIG do
    if rb(ENTRY + i - 1) ~= ENTRY_SIG[i] then return false end
  end
  return true
end

local function emit(event, detail)
  local sector = audioSector()
  local line = string.format(
    '%d\t%s\tpc=%04X\tstate=%02X\tstateAge=%d\tsig=%02X\t' ..
    'track=%02X\tpulse=%02X/%02X\telapsed=%d\tsector=%d\t' ..
    'base=%04X\tcmd=%02X\tband=%d\tpostStop=%d\t%s',
    frame, event, pcNow() & 0xFFFF, lastState & 0xFF,
    lastStateFrame >= 0 and (frame - lastStateFrame) or -1,
    rb(CDDA_SIG), rb(TRACK), rb(PULSE_A), rb(PULSE_B), elapsed(), sector,
    base(), rb(CTL_CMD), bandWrites, bandWritesAfterStop, detail or '')
  out:write(line .. '\n'); out:flush()
  emu.log(TAG .. ' ' .. line:gsub('\t', ' · '))
end

-- 실제 state writer를 관찰한다. endFrame의 뱅크가 바뀌어도 마지막 write 값은 보존한다.
emu.addMemoryCallback(function(_address, value)
  lastState = (value or 0) & 0xFF
  lastStateFrame = frame
  emit('STATE_WRITE', string.format('value=%02X', lastState))
end, emu.callbackType.write, STATE, STATE, CPU, MEM)

emu.addMemoryCallback(function()
  cddaArmed = true
  audioWasMoving = false
  audioStopped = false
  audioStopFrame = -1
  lastSector = nil
  stillFrames = 0
  emit('CDDA_ARM', '')
end, emu.callbackType.exec, CDDA_START, CDDA_START, CPU, MEM)

emu.addMemoryCallback(function()
  emit('TIMER_FINISH', 'fixed-duration finish path reached')
end, emu.callbackType.exec, FINISH, FINISH, CPU, MEM)

-- helper save/restore와 renderer가 같은 $5B83을 돌려 쓰므로 실행 시그니처로 구분한다.
emu.addMemoryCallback(function()
  if isHelper() then
    if rb(CTL_CMD) == 0 then
      helperSave = helperSave + 1
      emit('HELPER_SAVE', 'count=' .. helperSave)
    else
      helperRestore = helperRestore + 1
      local lag = audioStopFrame >= 0 and (frame - audioStopFrame) or -1
      emit('HELPER_RESTORE', string.format('count=%d lagAfterAudioStop=%d',
        helperRestore, lag))
    end
  else
    rendererEntry = rendererEntry + 1
    if rendererEntry <= 8 or audioStopped then
      emit('RENDERER_ENTRY', 'count=' .. rendererEntry)
    end
  end
end, emu.callbackType.exec, ENTRY, ENTRY, CPU, MEM)

-- VDC 포트 쓰기로 $7900-$7DBF 접근 횟수만 복원한다.
-- hot callback 안에서는 getState()를 부르지 않아 에뮬레이션을 느리게 하지 않는다.
local selReg, mawr = 0, 0
emu.addMemoryCallback(function(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF
  if port == 0 then
    selReg = value
  elseif port == 2 then
    if selReg == 0 then mawr = (mawr & 0xFF00) | value end
  elseif port == 3 then
    if selReg == 0 then
      mawr = (mawr & 0x00FF) | (value << 8)
    elseif selReg == 2 then
      local word = mawr & 0x7FFF
      if word >= VRAM_FIRST and word <= VRAM_LAST then
        bandWrites = bandWrites + 1
        if audioStopped then
          bandWritesAfterStop = bandWritesAfterStop + 1
          if not firstPostStopWrite then firstPostStopWrite = true end
        end
      end
      mawr = (mawr + 1) & 0xFFFF
    end
  end
end, emu.callbackType.write, 0x0000, 0x03FF, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  if not cddaArmed then return end

  local sector = audioSector()
  if sector >= 0 then
    if lastSector ~= nil and sector ~= lastSector then
      if not audioWasMoving then emit('AUDIO_MOVING', 'sector changed') end
      audioWasMoving = true
      stillFrames = 0
    elseif audioWasMoving and not audioStopped then
      stillFrames = stillFrames + 1
      if stillFrames == 12 then
        audioStopped = true
        audioStopFrame = frame
        emit('AUDIO_STOP', 'sector unchanged for 12 frames')
      end
    end
    lastSector = sector
  end

  local now = elapsed()
  for _, threshold in ipairs({ 2188, 2435, 2683 }) do
    if now >= threshold and not milestoneSeen[threshold] then
      milestoneSeen[threshold] = true
      emit('TIMER_' .. threshold, '')
    end
  end

  if firstPostStopWrite then
    firstPostStopWrite = false
    emit('VRAM_BAND_WRITE_AFTER_AUDIO_STOP',
      'new scene/engine wrote subtitle band after audio stopped')
  end

  if audioStopped and frame % 60 == 0 then
    emit('ORPHAN_TICK', string.format('afterStop=%d restoreCount=%d',
      frame - audioStopFrame, helperRestore))
  end
end, emu.eventType.endFrame)

local function finish()
  local verdict
  if audioStopFrame >= 0 and helperRestore > 0 then
    verdict = 'CHECK restore lag in HELPER_RESTORE'
  elseif audioStopFrame >= 0 then
    verdict = 'AUDIO STOPPED BUT RESTORE NOT OBSERVED'
  else
    verdict = 'AUDIO STOP NOT OBSERVED'
  end
  emit('END', string.format(
    '%s saves=%d restores=%d renderer=%d band=%d postStop=%d',
    verdict, helperSave, helperRestore, rendererEntry, bandWrites, bandWritesAfterStop))
  out:close()
end

emu.addEventCallback(finish, emu.eventType.scriptEnded)

out:write('frame\tevent\tpc\tstate\tstateAge\tsig\ttrack\tpulse\telapsed\tsector\tbase\tcmd\tband\tpostStop\tdetail\n')
out:flush()

emu.log(TAG .. ' loaded -- BIOS 0.4.6.48 CD-DA mid-skip lifecycle read-only probe')
emu.log('  첫 자막이 나온 뒤 스킵 · 키 입력/CPU RAM/AC/VRAM/state 쓰기 없음')
emu.log('  AUDIO_STOP -> STATE_WRITE/TIMER_FINISH/HELPER_RESTORE 순서를 자동 기록')
emu.log('  결과: ' .. OUT)
