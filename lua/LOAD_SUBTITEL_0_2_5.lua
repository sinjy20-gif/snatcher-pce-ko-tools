-- SUBTITEL 0.2.5 로더 -- 엔진 페이로드를 아케이드 카드에 얹는다
--
-- 아케이드 카드는 게임이 돌기 시작해야 잡힌다.  부팅 전에 쓰면 안 붙는다
-- (2026-08-22: BIOS 대기 화면에서 실행했더니 152 B 중 66 B 불일치).
-- 그래서 프레임 경계에서 쓰고, 붙을 때까지 재시도한다.
--
-- 안 붙은 상태로 음성이 시작되면 케이브가 쓰레기를 RAM 으로 복사해 실행한다.
-- 그러면 멈춘 원인이 0.2.5 인지 로더 탓인지 못 가른다 -- 반드시 "검증 통과" 를 보고 진행할 것.
--
--   1. 펌웨어를 SUBTITEL_0.2.5.pce 로 바꾸고 게임을 **다시 로드**한다
--   2. 스내처가 실제로 뜬 뒤 이 스크립트를 실행한다
--   3. "검증 통과" 를 확인하고 음성 대사까지 간다
--   4. 파워사이클/리셋 하면 AC 가 날아가므로 다시 실행해야 한다
--
--     Script -> Settings -> Restrictions -> Allow I/O and OS

local AC = emu.memType.pceArcadeCardRam
local AC_BASE = 0x1C0500
local PATH = "C:/snatcher/SUBTITEL/0.2.5.bin"
local RETRY = 300

local f = io.open(PATH, "rb")
if f == nil then emu.log("★ 페이로드를 못 열었다: " .. PATH); return end
local data = f:read("a"); f:close()
emu.log(string.format("SUBTITEL 0.2.5 로더 -- 페이로드 %d B.  게임이 돌면 얹는다", #data))

local tries, done = 0, false
emu.addEventCallback(function()
  if done then return end
  tries = tries + 1
  for i = 1, #data do emu.write(AC_BASE + i - 1, data:byte(i), AC) end
  local bad, first, last = 0, nil, nil
  for i = 1, #data do
    if emu.read(AC_BASE + i - 1, AC) ~= data:byte(i) then
      bad = bad + 1
      if first == nil then first = i - 1 end
      last = i - 1
    end
  end
  if bad == 0 then
    done = true
    emu.log(string.format("페이로드 %d B -> AC $%06X  검증 통과 (%d 번째 시도)", #data, AC_BASE, tries))
    emu.log("음성 대사까지 가면 된다.")
  elseif tries % 60 == 0 then
    emu.log(string.format("아직 -- %d/%d 불일치, +$%03X~+$%03X (%d 프레임째)",
      bad, #data, first or 0, last or 0, tries))
  end
  if not done and tries >= RETRY then
    done = true
    emu.log("★ 못 붙였다.  게임이 실제로 돌고 있는지 확인해라")
  end
end, emu.eventType.endFrame)
