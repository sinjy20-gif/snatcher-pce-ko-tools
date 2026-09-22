-- SUB 0.4.14 -- lightweight no-subtitle A/B
--
-- 0.4.12에서 무거운 0.4.11 IRQ/RAM 프로브를 완전히 제거한 경량판.
-- 기준 0.4.6.10 BIOS/디스크는 그대로 두고, E6800_0E 자막 시작만 차단한다.
-- 반드시 E6800_0E 음성이 시작되기 전 세이브에서 이 Lua 하나만 실행할 것.

local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce
local STATE = 0x7FDF
local CAVE = 0xFEC4
local DISABLED = 0xFE
local TARGET_END = 0x6800
local TARGET_RATE = 0x0E

local blocked = false
local tooLate = false

local function number(s, key)
  local v = s[key]
  return type(v) == 'number' and v or 0
end

local function targetPlaying()
  local ok, s = pcall(emu.getState)
  if not ok or not s or s['cdrom.adpcm.playing'] ~= true then return false end
  local finish = (number(s, 'cdrom.adpcm.readAddress') +
                  number(s, 'cdrom.adpcm.adpcmLength')) & 0xFFFF
  return finish == TARGET_END and
         number(s, 'cdrom.adpcm.playbackRate') == TARGET_RATE
end

-- 콜백은 이것 하나뿐이다. $FEC4 진입 직전에 state를 idle 고정으로 바꿔
-- helper/renderer의 draw, backup, restore가 시작되지 않게 한다.
emu.addMemoryCallback(function()
  if blocked or tooLate or not targetPlaying() then return end
  local st = emu.read(STATE, MEM) or 0xFF
  if st ~= 0 then
    tooLate = true
    emu.log(string.format(
      'SUB 0.4.14 TOO LATE: state=$%02X -- 더 앞 세이브에서 다시 실행', st))
    return
  end
  emu.write(STATE, DISABLED, MEM)
  blocked = true
  emu.log('SUB 0.4.14 ★ SUBTITLE START BLOCKED -- lightweight, probes 0')
end, emu.callbackType.exec, CAVE, CAVE, CPU, MEM)

-- 상태 표시는 차단되기 전과 오류일 때만 그린다. 차단 성공 뒤에는 화면 콜백도
-- 즉시 제거할 수 없으므로 아무 작업 없이 반환한다.
emu.addEventCallback(function()
  if blocked then return end
  if tooLate then
    emu.drawString(4, 4, '0.4.14 TOO LATE - LOAD EARLIER', 0xFF4040, 0x000000)
  else
    emu.drawString(4, 4, '0.4.14 WAIT E6800_0E', 0xFFFFFF, 0x000000)
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if blocked and (emu.read(STATE, MEM) or 0) == DISABLED then
    emu.write(STATE, 0, MEM)
  end
end, emu.eventType.scriptEnded)

emu.log('SUB 0.4.14 loaded -- lightweight subtitle blocker only')
emu.log('  0.4.11 IRQ/RAM probe 미포함 · 로그 파일 없음')
