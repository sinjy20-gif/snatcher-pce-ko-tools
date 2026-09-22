-- SUB 0.4.12
--
-- A/B 시험: 앞 자막 E6800_0E 의 **시작만** Lua 로 차단한 뒤,
-- 다음 음성 ADPCM_008FA4_FFFF_0E 가 정상 종료하는지 본다.
--
-- 기준 BIOS/디스크는 0.4.6.10 그대로 쓴다.  BIOS/AC/VRAM/엔진 이미지는
-- 고치지 않는다.  $FEC4 네이티브 문지기가 E6800_0E 를 승인하려는 바로 그
-- 순간 resident state $7FDF 를 $FE(idle 고정)로 바꾸어 자막 lifecycle 자체를
-- 시작하지 못하게 한다.  따라서 draw뿐 아니라 helper backup/restore도 안 돈다.
--
-- 반드시 E6800_0E 음성이 시작되기 전 세이브에서 이 Lua 하나만 로드할 것.
-- 이 파일은 0.4.11 읽기 전용 IRQ 프로브도 함께 불러온다.
--
-- 판정
--   "SUBTITLE START BLOCKED" 뒤 008FA4 통과
--       -> 자막 lifecycle(draw/restore 포함)이 필요한 원인
--   "SUBTITLE START BLOCKED" 뒤 같은 $E736 정지
--       -> 자막과 무관. BIOS 훅 3종 이분 탐색으로 이동
--   "TOO LATE"
--       -> 자막이 이미 시작된 뒤 로드한 것. 더 앞 세이브에서 다시 할 것

local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce
local STATE = 0x7FDF
local CAVE = 0xFEC4
local DISABLED = 0xFE
local TARGET_END = 0x6800
local TARGET_RATE = 0x0E

local armed = false
local blocked = false
local tooLate = false
local originalState = nil

local function number(s, key)
  local v = s[key]
  return type(v) == 'number' and v or 0
end

local function currentVoice()
  local ok, s = pcall(emu.getState)
  if not ok or not s or s['cdrom.adpcm.playing'] ~= true then return nil end
  local read = number(s, 'cdrom.adpcm.readAddress')
  local len = number(s, 'cdrom.adpcm.adpcmLength')
  return (read + len) & 0xFFFF, number(s, 'cdrom.adpcm.playbackRate')
end

-- exec callback은 $FEC4의 첫 명령이 실행되기 전에 호출된다. 이때 state=0이면
-- 아직 resident가 helper/renderer를 복사하지 않았으므로 완전히 깨끗하게 막힌다.
emu.addMemoryCallback(function()
  if blocked or tooLate then return end
  local finish, rate = currentVoice()
  if finish ~= TARGET_END or rate ~= TARGET_RATE then return end

  armed = true
  local st = emu.read(STATE, MEM) or 0xFF
  if st ~= 0 then
    tooLate = true
    emu.log(string.format(
      'SUB 0.4.12 TOO LATE: E6800_0E cave state=$%02X -- 더 앞 세이브에서 재시작', st))
    return
  end

  originalState = st
  emu.write(STATE, DISABLED, MEM)
  blocked = true
  emu.log('SUB 0.4.12 ★ SUBTITLE START BLOCKED: E6800_0E · draw/backup/restore 0회')
  emu.log('  이제 그대로 진행해서 다음 ADPCM_008FA4가 넘어가는지만 볼 것')
end, emu.callbackType.exec, CAVE, CAVE, CPU, MEM)

emu.addEventCallback(function()
  local text
  local color
  if blocked then
    text, color = '0.4.12 NO-SUB A/B: BLOCKED OK', 0x40FF40
  elseif tooLate then
    text, color = '0.4.12 TOO LATE - LOAD EARLIER', 0xFF4040
  elseif armed then
    text, color = '0.4.12 ARMING...', 0xFFFF40
  else
    text, color = '0.4.12 WAIT E6800_0E', 0xFFFFFF
  end
  emu.drawString(4, 4, text, color, 0x000000)
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  -- 진단 중 우리가 $FE로 만든 경우에만 원상복구한다.
  if blocked and originalState ~= nil and (emu.read(STATE, MEM) or 0) == DISABLED then
    emu.write(STATE, originalState, MEM)
  end
end, emu.eventType.scriptEnded)

emu.log('SUB 0.4.12 loaded -- no-subtitle A/B + 0.4.11 IRQ probe')
emu.log('  E6800_0E 시작 전 세이브에서 실행 · 기준 0.4.6.10 BIOS/디스크 그대로')

dofile('C:/snatcher/lua/SUB/0.4.11.lua')
