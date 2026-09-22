-- SUB 0.4.19 -- stale fingerprint false-trigger guard
--
-- 0.4.18 실측:
--   실제 ADPCM = 008FA4_FFFF_0E 인데 $FEC4가 E6800_0E gate를 통과시켜
--   subtitle state를 0 -> 1 -> 2로 올린 직후 $E736에서 정지했다.
--
-- 원인은 새 ADPCM은 이미 playing인데 게임의 판정 RAM $22A6/$22A7/$22AA가
-- 앞 음성의 00/68/0E를 잠깐 유지하는 race다. 이 Lua는 실제 에뮬레이터 ADPCM
-- finish/rate와 RAM 지문이 어긋나는 동안 그 $FEC4 호출만 idle로 돌린다.
-- genuine E6800_0E는 건드리지 않으므로 자막은 정상 표시되어야 한다.

local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce
local CAVE = 0xFEC4
local AFTER_CAVE = 0x7F52
local STATE = 0x7FDF
local TEMP_IDLE = 0xFE
local TARGET_FINISH = 0x6800
local TARGET_RATE = 0x0E

local pendingRestore = false
local blocked = 0

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
  return finish, number(s,'cdrom.adpcm.playbackRate'),
         number(s,'cdrom.scsi.sector')
end

emu.addMemoryCallback(function()
  if pendingRestore or byte(STATE) ~= 0 then return end

  local finish, rate, sector = actualVoice()
  if not finish then return end

  -- BIOS gate가 곧 승인할 RAM 지문인지 확인한다.
  local ramLooksTarget = byte(0x22A6) == 0x00 and
                         byte(0x22A7) == 0x68 and
                         byte(0x22AA) == TARGET_RATE
  local actualIsTarget = finish == TARGET_FINISH and rate == TARGET_RATE
  if not ramLooksTarget or actualIsTarget then return end

  -- 이 FEC4 한 번만 FE idle 경로로 보낸다. 반환 직후 $7F52에서 0으로 복구한다.
  emu.write(STATE, TEMP_IDLE, MEM)
  pendingRestore = true
  blocked = blocked + 1
  emu.log(string.format(
    'SUB 0.4.19 ★ FALSE TRIGGER BLOCK #%d: RAM=E6800_0E actual=%06X_%04X_%02X',
    blocked, sector, finish, rate))
end, emu.callbackType.exec, CAVE, CAVE, CPU, MEM)

emu.addMemoryCallback(function()
  if not pendingRestore then return end
  if byte(STATE) == TEMP_IDLE then emu.write(STATE, 0, MEM) end
  pendingRestore = false
end, emu.callbackType.exec, AFTER_CAVE, AFTER_CAVE, CPU, MEM)

emu.addEventCallback(function()
  if blocked > 0 then
    emu.drawString(4, 4, string.format('0.4.19 FALSE BLOCK %d', blocked),
                   0x40FF40, 0x000000)
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if pendingRestore and byte(STATE) == TEMP_IDLE then emu.write(STATE, 0, MEM) end
end, emu.eventType.scriptEnded)

emu.log('SUB 0.4.19 loaded -- measured stale-fingerprint guard')
emu.log('  genuine E6800 subtitle ON · false next-voice trigger only blocked')
