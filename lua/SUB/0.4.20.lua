-- SUB 0.4.20 -- latched stale-fingerprint guard
--
-- 0.4.19는 같은 false voice 동안 매 $FEC4 호출마다 FE->0을 반복해 수천 번
-- 차단했다. 이 판은 실제 ADPCM identity 하나를 잡으면 그 음성이 끝나거나
-- identity가 바뀔 때까지 state=$FE를 유지한다. 차단/로그는 음성당 한 번이다.
-- genuine E6800_0E 자막은 그대로 허용한다.

local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce
local CAVE = 0xFEC4
local STATE = 0x7FDF
local HELD_IDLE = 0xFE
local TARGET_FINISH = 0x6800
local TARGET_RATE = 0x0E

local held = nil
local blockedVoices = 0

local function byte(a) return emu.read(a & 0xFFFF, MEM) or 0 end

local function number(s, k)
  local v = s[k]
  return type(v) == 'number' and v or 0
end

local function actualVoice()
  local ok, s = pcall(emu.getState)
  if not ok or not s or s['cdrom.adpcm.playing'] ~= true then return nil end
  local finish = (number(s,'cdrom.adpcm.readAddress') +
                  number(s,'cdrom.adpcm.adpcmLength')) & 0xFFFF
  local rate = number(s,'cdrom.adpcm.playbackRate')
  local sector = number(s,'cdrom.scsi.sector')
  return {sector=sector, finish=finish, rate=rate,
          id=string.format('%06X_%04X_%02X',sector,finish,rate)}
end

local function release(reason)
  if not held then return end
  if byte(STATE) == HELD_IDLE then emu.write(STATE, 0, MEM) end
  emu.log(string.format('SUB 0.4.20 release %s (%s)', held.id, reason))
  held = nil
end

emu.addMemoryCallback(function()
  if held or byte(STATE) ~= 0 then return end
  local voice = actualVoice()
  if not voice then return end

  local ramLooksTarget = byte(0x22A6) == 0x00 and
                         byte(0x22A7) == 0x68 and
                         byte(0x22AA) == TARGET_RATE
  local actualIsTarget = voice.finish == TARGET_FINISH and
                         voice.rate == TARGET_RATE
  if not ramLooksTarget or actualIsTarget then return end

  emu.write(STATE, HELD_IDLE, MEM)
  held = voice
  blockedVoices = blockedVoices + 1
  emu.log(string.format(
    'SUB 0.4.20 ★ FALSE VOICE BLOCK #%d: RAM=E6800_0E actual=%s (latched)',
    blockedVoices, voice.id))
end, emu.callbackType.exec, CAVE, CAVE, CPU, MEM)

-- 프레임당 한 번만 실제 voice identity를 본다. 같은 음성 동안에는 FE를 그대로
-- 유지하므로 $FEC4 호출 횟수와 무관하게 추가 write/log가 전혀 없다.
emu.addEventCallback(function()
  if held then
    local voice = actualVoice()
    if not voice then
      release('playback ended')
    elseif voice.id ~= held.id then
      release('voice changed to '..voice.id)
    end
  end
  if blockedVoices > 0 then
    emu.drawString(4,4,string.format('0.4.20 FALSE VOICES %d',blockedVoices),
                   0x40FF40,0x000000)
  end
end,emu.eventType.endFrame)

emu.addEventCallback(function() release('script stopped') end,
  emu.eventType.scriptEnded)

emu.log('SUB 0.4.20 loaded -- latched stale-fingerprint guard')
emu.log('  genuine E6800 subtitle ON · one block per false voice')
