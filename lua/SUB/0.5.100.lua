-- SUB 0.5.100 -- 정상 CD-DA 종료와 오프닝 스킵의 게임 분기 비교 (read-only)
--
-- BIOS 0.4.6.48에서 이 파일 하나만 로드하고 Power Cycle한다.
-- 같은 절차를 두 번 수행한다.
--   A: 아무것도 누르지 않고 정상 종료
--   B: 첫 자막이 나온 뒤 오프닝 스킵
--
-- CD audio sector가 멈춘 프레임을 앵커로 삼아 다음을 자동 저장한다.
--   · 직전 game overlay $6000-$7FFF 실행 주소 8,192개
--   · 직전 RAM $2000-$27FF write 4,096개
--   · 정지 순간 RAM $2200-$27FF 전체 snapshot
--   · 이후 90프레임의 같은 실행/write 기록과 snapshot
--
-- 메모리/state/VRAM/AC/입력 쓰기 없음. 로그도 캡처 순간에만 파일로 쓴다.

local VERSION = '0.5.100'
local TAG = 'SUB ' .. VERSION
local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/sub/cdda_skip_branch_0_5_100_' .. STAMP .. '.tsv'
local out = assert(io.open(OUT, 'w'), 'cannot open ' .. OUT)
out:write('phase\tseq\tframe\tkind\taddress\tvalue\tdetail\n')
out:flush()

local CDDA_START = 0xF798
local STATE, SIG, ELAPSED = 0x7FDF, 0x5DDA, 0x5E1D
local TRACK, PULSE_A, PULSE_B = 0x26F9, 0x263C, 0x2638
local STATUS = 0x26F5
local TRACE_FROM = 2000
local STALL_FRAMES = 3
local POST_FRAMES = 90
local PC_CAP, WR_CAP = 8192, 4096

local frame, armCount, captureCount = 0, 0, 0
local armed, traceEnabled, captured = false, false, false
local lastSector = nil
local sectorMoved = false
local stillFrames = 0
local stopFrame = -1
local postLeft = -1

local pcFrame, pcAddr, pcPos, pcCount = {}, {}, 1, 0
local wrFrame, wrAddr, wrValue, wrPos, wrCount = {}, {}, {}, 1, 0

local function rb(at)
  return emu.read(at, MEM) or 0
end

local function elapsed()
  return rb(ELAPSED) | (rb(ELAPSED + 1) << 8)
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

local function resetRings()
  pcFrame, pcAddr, pcPos, pcCount = {}, {}, 1, 0
  wrFrame, wrAddr, wrValue, wrPos, wrCount = {}, {}, {}, 1, 0
end

local function pushPC(address)
  if not traceEnabled then return end
  pcFrame[pcPos], pcAddr[pcPos] = frame, address & 0xFFFF
  pcPos = pcPos % PC_CAP + 1
  if pcCount < PC_CAP then pcCount = pcCount + 1 end
end

local function pushWrite(address, value)
  if not traceEnabled then return end
  wrFrame[wrPos], wrAddr[wrPos], wrValue[wrPos] =
    frame, address & 0xFFFF, (value or 0) & 0xFF
  wrPos = wrPos % WR_CAP + 1
  if wrCount < WR_CAP then wrCount = wrCount + 1 end
end

local function writeRing(phase, kind, count, cap, pos, frames, addresses, values)
  local first = count == cap and pos or 1
  for seq = 1, count do
    local i = ((first + seq - 2) % cap) + 1
    out:write(string.format('%s\t%d\t%d\t%s\t%04X\t%s\t\n',
      phase, seq, frames[i] or -1, kind, addresses[i] or 0,
      values and string.format('%02X', values[i] or 0) or ''))
  end
end

local function marker(phase, detail)
  out:write(string.format('%s\t0\t%d\tMARK\t0000\t\t%s\n', phase, frame,
    detail or ''))
end

local function snapshot(phase)
  for at = 0x2200, 0x27FF do
    out:write(string.format('%s\t%d\t%d\tSNAP\t%04X\t%02X\t\n',
      phase, at - 0x2200 + 1, frame, at, rb(at)))
  end
end

local function anchorDetail()
  return string.format(
    'sector=%d elapsed=%d state=%02X sig=%02X track=%02X pulse=%02X/%02X status=%02X',
    audioSector(), elapsed(), rb(STATE), rb(SIG), rb(TRACK), rb(PULSE_A),
    rb(PULSE_B), rb(STATUS))
end

local function dumpCurrent(phase)
  marker(phase, anchorDetail())
  writeRing(phase, 'PC', pcCount, PC_CAP, pcPos, pcFrame, pcAddr, nil)
  writeRing(phase, 'WRITE', wrCount, WR_CAP, wrPos, wrFrame, wrAddr, wrValue)
  snapshot(phase)
  out:flush()
end

emu.addMemoryCallback(function()
  armCount = armCount + 1
  armed = true
  traceEnabled = false
  captured = false
  lastSector = nil
  sectorMoved = false
  stillFrames = 0
  stopFrame = -1
  postLeft = -1
  resetRings()
  emu.log(string.format('%s CDDA%d ARM · 정상 종료 또는 자막 뒤 스킵을 진행',
    TAG, armCount))
end, emu.callbackType.exec, CDDA_START, CDDA_START, CPU, MEM)

-- 주소 인자는 실행 중인 PC이므로 hot path에서 getState()가 필요 없다.
emu.addMemoryCallback(function(address)
  pushPC(address)
end, emu.callbackType.exec, 0x6000, 0x7FFF, CPU, MEM)

emu.addMemoryCallback(function(address, value)
  pushWrite(address, value)
end, emu.callbackType.write, 0x2000, 0x27FF, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  if not armed or captured then return end

  local nowElapsed = elapsed()
  if nowElapsed >= TRACE_FROM then traceEnabled = true end

  local sector = audioSector()
  if sector >= 0 then
    if lastSector ~= nil and sector ~= lastSector then
      sectorMoved = true
      stillFrames = 0
    elseif sectorMoved and stopFrame < 0 then
      stillFrames = stillFrames + 1
      if stillFrames == STALL_FRAMES then
        stopFrame = frame
        local phase = string.format('CDDA%d_PRE_STOP', armCount)
        dumpCurrent(phase)
        emu.log(string.format('%s ★ %s f%d %s', TAG, phase, frame, anchorDetail()))
        resetRings()
        -- 아래 countdown이 같은 endFrame에서도 한 번 실행되므로 +1로 시작한다.
        postLeft = POST_FRAMES + 1
      end
    end
    lastSector = sector
  end

  if stopFrame >= 0 and postLeft >= 0 then
    postLeft = postLeft - 1
    if postLeft == 0 then
      local phase = string.format('CDDA%d_POST_90F', armCount)
      dumpCurrent(phase)
      captured = true
      captureCount = captureCount + 1
      traceEnabled = false
      emu.log(string.format('%s ★ %s COMPLETE f%d · stop+%d · %s',
        TAG, phase, frame, frame - stopFrame, OUT))
    end
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if not captured then
    marker(string.format('CDDA%d_END_INCOMPLETE', armCount), anchorDetail())
    out:flush()
  end
  emu.log(string.format('%s END arms=%d captures=%d', TAG, armCount, captureCount))
  out:close()
end, emu.eventType.scriptEnded)

emu.log(TAG .. ' loaded -- normal-end vs opening-skip branch trace · read-only')
emu.log('  1회 정상 종료, 1회 첫 자막 뒤 스킵 · 각각 Power Cycle')
emu.log('  PRE_STOP + POST_90F 자동 저장 · 키/CPU RAM/VRAM/AC/state 쓰기 없음')
emu.log('  결과: ' .. OUT)
