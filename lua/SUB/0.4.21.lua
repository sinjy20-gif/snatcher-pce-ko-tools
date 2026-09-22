-- SUB 0.4.21 -- one latch per ADPCM playback session
--
-- 0.4.20 런타임 합격. 다만 SCSI sector/read pointer가 재생 중 계속 움직여
-- 한 음성을 여러 identity로 잘못 세었다. 이 판은 false trigger를 잡으면
-- cdrom.adpcm.playing이 false가 될 때까지 FE를 유지한다. 한 재생당 차단 1회.
-- genuine E6800_0E 자막은 정상 허용한다.

local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce
local CAVE = 0xFEC4
local STATE = 0x7FDF
local HELD_IDLE = 0xFE
local TARGET_FINISH = 0x6800
local TARGET_RATE = 0x0E

local held = false
local blockedSessions = 0

local function byte(a) return emu.read(a & 0xFFFF, MEM) or 0 end

local function number(s,k)
  local v=s[k]
  return type(v)=='number' and v or 0
end

local function adpcmState()
  local ok,s=pcall(emu.getState)
  if not ok or not s then return false,0,0,0 end
  local playing=s['cdrom.adpcm.playing']==true
  local finish=(number(s,'cdrom.adpcm.readAddress')+
                number(s,'cdrom.adpcm.adpcmLength'))&0xFFFF
  return playing,number(s,'cdrom.scsi.sector'),finish,
         number(s,'cdrom.adpcm.playbackRate')
end

local function release(reason)
  if not held then return end
  if byte(STATE)==HELD_IDLE then emu.write(STATE,0,MEM) end
  held=false
  emu.log('SUB 0.4.21 release false playback ('..reason..')')
end

emu.addMemoryCallback(function()
  if held or byte(STATE)~=0 then return end
  local playing,sector,finish,rate=adpcmState()
  if not playing then return end

  local ramLooksTarget=byte(0x22A6)==0x00 and
                       byte(0x22A7)==0x68 and
                       byte(0x22AA)==TARGET_RATE
  local actualIsTarget=finish==TARGET_FINISH and rate==TARGET_RATE
  if not ramLooksTarget or actualIsTarget then return end

  emu.write(STATE,HELD_IDLE,MEM)
  held=true
  blockedSessions=blockedSessions+1
  emu.log(string.format(
    'SUB 0.4.21 ★ FALSE PLAYBACK BLOCK #%d: RAM=E6800_0E actual_start=%06X_%04X_%02X',
    blockedSessions,sector,finish,rate))
end,emu.callbackType.exec,CAVE,CAVE,CPU,MEM)

emu.addEventCallback(function()
  if held then
    local playing=adpcmState()
    if not playing then release('playback ended') end
  end
  if blockedSessions>0 then
    emu.drawString(4,4,string.format('0.4.21 FALSE PLAYBACKS %d',blockedSessions),
                   0x40FF40,0x000000)
  end
end,emu.eventType.endFrame)

emu.addEventCallback(function() release('script stopped') end,
  emu.eventType.scriptEnded)

emu.log('SUB 0.4.21 loaded -- one stale-key block per ADPCM playback')
emu.log('  0.4.20 runtime result preserved · reduced latch/log only')
