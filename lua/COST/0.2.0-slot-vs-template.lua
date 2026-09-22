-- lua/COST/0.2.0-slot-vs-template.lua   (옛 이름 PROBE_ARM_TRANSPORT_0_2_0.lua)
-- ★판번호는 COST 폴더 기준으로 다시 매겼다 (2026-09-05, 소유자 요청).
--   덤프 경로도 같이 바꿨다 -- 로그와 코드가 어긋나면 로그를 못 읽는다.
--   덤프: snatcher_tool/logs/cost_v020.tsv
--
-- PROBE_ARM_TRANSPORT 0.2.0 -- 671 B 재적재가 정말 필요한가
--
-- 0.1.0 이 답한 것 (실측)
-- ----------------------
--   $1A10 쓰기 707~746 회가 arm 마다 몰린다 = 엔진 671 B + 나머지 ~50
--   arm 간격 중앙값 ~235 프레임.  팩의 클립 중앙값 199 프레임과 맞는다
--   -> **클립 하나에 arm 하나.  671 B 를 매번 나른다** (소유자 예상대로)
--
--   ⚠ 0.1.0 의 `클립 0` 은 발견이 아니라 결함이었다.  $180D 를 Lua 로 그냥
--     읽었는데 이 저장소에 "ADPCM RAM 표본을 읽으려면 $180D 래치가 필요하다"
--     고 이미 적혀 있다.  그래서 0.2.0 은 $180D 를 **안 쓴다** -- STATE 만으로
--     센다 (0->1 = arm, 1->0 = 클립 끝).
--
-- 이번 질문 (소유자)
-- -----------------
-- 클립마다 다시 채우는데, 값이 실제로 달라지는 건 16 B 뿐으로 보인다.
--
--   selector 9 B · 즉치 3 B (음성마다 다른 VRAM 자리) · 헬퍼 CTL 4 B
--
-- 나머지 655 B 는 매번 같은 값을 다시 쓴다.  **정말 그런가?**
-- 그렇다면 "직전도 ADPCM 이면 16 B 만 다시 박기" 가 성립하고 23.6 줄이 사라진다.
--
-- 어떻게 가르나 -- 두 시점을 뜬다
-- -------------------------------
--   A  arm 직후    (템플릿 + 이번 음성 패치)
--   B  클립 끝     (렌더러가 한 바퀴 돌고 난 뒤)
--
--   A == B        렌더러가 자기 코드를 안 고친다
--                 -> 다음 arm 은 16 B 만 박으면 된다.  655 B 는 순수 낭비
--   A != B        자기수정이 있다.  원본 복원이 필요한 게 맞다
--                 -> 어디가 바뀌는지 오프셋이 나오므로 그만큼만 되돌리면 된다
--
-- 템플릿과도 비교해서 "패치가 실제로 건드린 자리" 를 같이 낸다.
--
-- ⚠ 화면에 아무것도 안 그린다.
-- ⚠ 콜백은 표시만 하고, 671 B 읽기는 프레임 끝에서 한다 (0.1.0 의 교훈).
--
--   dump  snatcher_tool/logs/cost_v020.tsv   ★프로브와 같은 판번호

local OUT = "C:/snatcher/snatcher_tool/logs/cost_v020.tsv"

local AC_WRITE   = 0x1A10
local STATE      = 0x7FDF
local AC_ENGINE  = 0x1F1F00     -- 활성 슬롯 (덮어쓰기 대상)
local AC_TEMPL   = 0x1FE400     -- 안전한 원본
local ENGINE_LEN = 671
local BURST      = 512

local cpu = emu.memType.cpu
local ac  = emu.memType.pceArcadeCardRam

local acw, frame = 0, 0
local arms, ends, bursts, total_ac = 0, 0, 0, 0
local last_state = -1
local pending = nil            -- "A" 또는 "B" -- 이번 프레임 끝에 뜰 것
local snapA = nil              -- arm 직후 이미지
local rows = {}
local verdicts = {}

local function say(m) emu.log(m); print(m) end

local function grab(base)
  local t = {}
  for i = 0, ENGINE_LEN - 1 do t[i] = emu.read(base + i, ac) end
  return t
end

local function diff(a, b)
  local d = {}
  for i = 0, ENGINE_LEN - 1 do
    if a[i] ~= b[i] then d[#d + 1] = i end
  end
  return d
end

local function brief(d)
  if #d == 0 then return "(없음)" end
  local p = {}
  for i = 1, math.min(#d, 12) do p[#p + 1] = string.format("+%d", d[i]) end
  if #d > 12 then p[#p + 1] = "..." end
  return table.concat(p, " ")
end

emu.addMemoryCallback(function()
  acw = acw + 1
end, emu.callbackType.write, AC_WRITE, AC_WRITE, emu.cpuType.pce, cpu)

emu.addMemoryCallback(function(addr, value)
  if value == 1 and last_state ~= 1 then
    arms = arms + 1
    pending = "A"
  elseif value == 0 and last_state == 1 then
    ends = ends + 1
    pending = "B"
  end
  last_state = value
end, emu.callbackType.write, STATE, STATE, emu.cpuType.pce, cpu)

emu.addEventCallback(function()
  frame = frame + 1
  total_ac = total_ac + acw
  if acw >= BURST then
    bursts = bursts + 1
    rows[#rows + 1] = { frame = frame, writes = acw, arms = arms }
  end
  acw = 0

  if pending == "A" then
    snapA = grab(AC_ENGINE)
    local dt = diff(snapA, grab(AC_TEMPL))
    say(("  f%-8d [A] arm %d 직후 -- 템플릿과 다른 바이트 %d개  %s")
        :format(frame, arms, #dt, brief(dt)))
    verdicts[#verdicts + 1] = { frame = frame, kind = "A", n = #dt, list = dt }
    pending = nil
  elseif pending == "B" then
    if snapA then
      local d = diff(snapA, grab(AC_ENGINE))
      say(("  f%-8d [B] 클립 끝 -- ★arm 직후와 다른 바이트 %d개  %s")
          :format(frame, #d, brief(d)))
      verdicts[#verdicts + 1] = { frame = frame, kind = "B", n = #d, list = d }
    end
    pending = nil
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  local f = io.open(OUT, "w")
  if f then
    f:write("frame\tkind\tdiff_bytes\toffsets\n")
    for _, v in ipairs(verdicts) do
      local p = {}
      for _, o in ipairs(v.list) do p[#p + 1] = tostring(o) end
      f:write(("%d\t%s\t%d\t%s\n"):format(v.frame, v.kind, v.n,
                                          table.concat(p, ",")))
    end
    f:close()
  end
  say("")
  say(("프레임 %d · arm %d · 클립끝 %d · 적재 프레임 %d · $1A10 쓰기 %d")
      :format(frame, arms, ends, bursts, total_ac))

  local worst = -1
  local nB = 0
  for _, v in ipairs(verdicts) do
    if v.kind == "B" then nB = nB + 1; if v.n > worst then worst = v.n end end
  end
  say("")
  if nB == 0 then
    say("★ B 표본이 없다 -- 클립이 끝나는 것을 못 봤다.  판정 불가")
    say("  (음성이 있는 장면을 지나고, 그 음성이 끝날 때까지 두고 볼 것)")
  elseif worst == 0 then
    say("-> 렌더러는 자기 코드를 **안 고친다** (B 전부 0 바이트 차이)")
    say(("   즉 655 B 는 매번 같은 값을 다시 쓰는 것이다."))
    say("   '직전도 ADPCM 이면 16 B 만 다시 박기' 가 성립한다 -> 23.6 줄 절약")
  else
    say(("-> 자기수정이 있다.  최대 %d 바이트가 실행 중에 바뀐다"):format(worst))
    say("   그 오프셋만 되돌리면 되므로, 전량 복원보다는 여전히 싸다")
  end
  say(("dump  %s"):format(OUT))
end, emu.eventType.scriptEnded)

say("PROBE_ARM_TRANSPORT 0.2.0 -- 세고, arm 직후/클립끝 두 번 뜬다")
say("  $180D 는 안 쓴다 (래치 필요).  STATE 만으로 센다")
