-- SUBTITEL 0.2.7 로더 -- 엔진 페이로드 + 매직값을 아케이드 카드에 얹는다
--
-- 0.2.5 로더와 다른 점 -- 순서가 전부다
-- --------------------------------------
-- 0.2.5 로더 헤더가 이 위험을 이미 적어 두었다:
--
--     안 붙은 상태로 음성이 시작되면 케이브가 쓰레기를 RAM 으로 복사해 실행한다.
--
-- 실제로 그것이 부팅 멈춤의 원인이었다 (2026-08-23 확정).  0.2.5/0.2.6 케이브는
-- Lua 실행 여부와 무관하게 설치를 강행했다.  게임이 자기 IRQ1 을 설치한 뒤
-- ADPCM 이 한 번이라도 울리면 게이트 5 조건이 전부 참이 되기 때문이다.
--
-- 0.2.7 케이브는 설치 직전에 AC $1C04F0 의 매직 'K' 'O' 를 확인한다.
-- 이 로더는 **페이로드를 다 얹고 검증에 통과한 뒤에만** 매직을 쓴다.  그래서
--
--     매직이 보인다  ==  페이로드가 온전히 AC 에 있다
--
-- 가 성립한다.  반대 순서로 쓰면 반쯤 쓰인 페이로드를 케이브가 온전한 것으로
-- 오인할 수 있다.
--
-- 쓰는 법
--   1. 펌웨어를 0.2.7.pce 로 바꾸고 게임을 **다시 로드**한다
--   2. 스내처가 실제로 뜬 뒤 이 스크립트를 실행한다
--   3. "매직 기록 완료" 를 확인하고 음성 대사까지 간다
--   4. 파워사이클/리셋 하면 AC 가 날아가므로 다시 실행해야 한다
--
--   Script -> Settings -> Restrictions -> Allow I/O and OS
--
-- 이번 판의 판정
--   Lua 를 안 돌리고 부팅   -> 매직이 없다 -> 케이브가 설치를 건너뛴다 -> 정상 부팅해야 한다
--   Lua 를 돌리고 음성      -> 매직이 있다 -> 설치된다

local AC = emu.memType.pceArcadeCardRam
local AC_ENGINE = 0x1C0500
local AC_MAGIC = AC_ENGINE - 0x10          -- $1C04F0.  케이브와 반드시 같아야 한다
local MAGIC = { 0x4B, 0x4F }               -- 'K' 'O'
local PATH = "C:/snatcher/SUBTITEL/0.2.7.bin"
local RETRY = 300

local f = io.open(PATH, "rb")
if f == nil then emu.log("★ 페이로드를 못 열었다: " .. PATH) return end
local data = f:read("a"); f:close()
emu.log(string.format("SUBTITEL 0.2.7 로더 -- 페이로드 %d B", #data))

-- 먼저 매직을 지운다.  이전 세션 잔재가 남아 있으면 안 된다
for i = 1, #MAGIC do emu.write(AC_MAGIC + i - 1, 0x00, AC) end

local tries, done = 0, false
emu.addEventCallback(function()
  if done then return end
  tries = tries + 1

  for i = 1, #data do emu.write(AC_ENGINE + i - 1, data:byte(i), AC) end

  local bad, first, last = 0, nil, nil
  for i = 1, #data do
    if emu.read(AC_ENGINE + i - 1, AC) ~= data:byte(i) then
      bad = bad + 1
      if first == nil then first = i - 1 end
      last = i - 1
    end
  end

  if bad == 0 then
    -- ★ 검증 통과 뒤에만 매직을 쓴다
    for i = 1, #MAGIC do emu.write(AC_MAGIC + i - 1, MAGIC[i], AC) end
    local ok = true
    for i = 1, #MAGIC do
      if emu.read(AC_MAGIC + i - 1, AC) ~= MAGIC[i] then ok = false end
    end
    done = true
    if ok then
      emu.log(string.format("페이로드 %d B -> AC $%06X  검증 통과 (%d 번째 시도)",
              #data, AC_ENGINE, tries))
      emu.log(string.format("매직 기록 완료 -> AC $%06X = %02X %02X", AC_MAGIC, MAGIC[1], MAGIC[2]))
      emu.log("음성 대사까지 가면 된다.")
    else
      emu.log("★ 페이로드는 붙었는데 매직이 안 붙는다 -- AC 주소를 확인해라")
    end
  elseif tries % 60 == 0 then
    emu.log(string.format("아직 -- %d/%d 불일치, +$%03X~+$%03X (%d 프레임째)",
      bad, #data, first or 0, last or 0, tries))
  end

  if not done and tries >= RETRY then
    done = true
    emu.log("★ 못 붙였다.  게임이 실제로 돌고 있는지 확인해라 (매직은 안 썼다)")
  end
end, emu.eventType.endFrame)
