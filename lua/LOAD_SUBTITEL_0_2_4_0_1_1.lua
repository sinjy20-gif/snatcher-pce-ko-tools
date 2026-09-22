-- SUBTITEL 0.2.4 로더 0.1.1 -- 프레임 경계에서 쓰고, 붙을 때까지 재시도한다
--
-- 0.1.0 에서 바뀐 것
-- ---------------------------------------------------------------------------
-- 0.1.0 은 스크립트를 부르는 즉시 AC 에 썼다.  그런데 **아케이드 카드는 게임이
-- 돌기 시작해야 잡힌다.**  부팅 전에 쓰면 붙지 않는다 (2026-08-22: 152 B 중 66 B
-- 불일치).  그 상태로 음성이 시작되면 케이브가 쓰레기를 RAM 으로 복사해 실행하고,
-- 그러면 멈춘 원인이 0.2.4 인지 로더 탓인지 못 가른다.
--
-- 그래서 이 판은
--   1. 스크립트를 언제 실행하든 **프레임 경계에서** 쓴다
--   2. 되읽어 검증하고, 어긋나면 다음 프레임에 다시 쓴다 (최대 RETRY 회)
--   3. 붙은 뒤에는 아무 일도 안 한다 -- 게임에 부담이 없다
--
-- 붙지 않으면 어긋난 구간을 찍어준다.  그게 다음 단서다.
--
--     Script -> Settings -> Restrictions -> Allow I/O and OS

local AC = emu.memType.pceArcadeCardRam
local AC_BASE = 0x1C0500          -- cave_manual_ac 의 life.set_ac(a,0x1C0500)
local PATH = "C:/snatcher/SUBTITEL/0.2.4.bin"
local RETRY = 120                 -- 프레임 단위.  2 초쯤

local f = io.open(PATH, "rb")
if f == nil then emu.log("★ 페이로드를 못 열었다: " .. PATH); return end
local data = f:read("a"); f:close()
emu.log(string.format("로더 0.1.1 -- 페이로드 %d B.  게임이 돌기 시작하면 얹는다", #data))

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
    emu.log(string.format("SUBTITEL 0.2.4 페이로드 %d B -> AC $%06X  검증 통과 (%d 번째 시도)",
      #data, AC_BASE, tries))
    emu.log("이제 음성 대사까지 가면 된다.  멈추면 30 초 더 두고 Stop.")
  elseif tries % 30 == 0 then
    emu.log(string.format("아직 안 붙었다 -- %d/%d 바이트 불일치, 어긋난 구간 +$%03X~+$%03X (%d 프레임째)",
      bad, #data, first or 0, last or 0, tries))
  end

  if not done and tries >= RETRY then
    done = true
    emu.log(string.format("★ %d 프레임 동안 못 붙였다.  게임이 실제로 돌고 있는지 확인해라", RETRY))
  end
end, emu.eventType.endFrame)
