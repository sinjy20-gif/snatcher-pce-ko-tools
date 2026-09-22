-- PROBE 프레임 비용 0.1.0 -- 버벅임이 우리 것인지 게임 것인지 가른다
--
-- 왜
-- ---------------------------------------------------------------------------
-- 2026-08-22 새벽, 적재 쪽은 숫자로 좋아졌는데 (첫 대사 한 번에 CD 68회 -> 팩을
-- 나눠 총 59회, 그 뒤 75초간 추가 0회) 체감이 안 바뀌었다.  그러면 원인이 적재가
-- 아니다.  더 추측하지 말고 **프레임을 직접 잰다.**
--
-- 무엇을 재나
-- ---------------------------------------------------------------------------
--   1. 프레임 간격          masterClock 차.  게임이 프레임 안에 일을 못 끝내면 늘어난다
--   2. 헬퍼 체류            $BCD2-$C000 안에서 실행된 명령 수.  그것이 우리 몫이다
--   3. 둘의 상관            헬퍼가 돈 프레임만 넘치는가, 아니면 그냥 다 넘치는가
--
-- 3 번이 핵심이다.  헬퍼가 안 돈 프레임도 똑같이 넘치면 우리 탓이 아니다.
--
-- 원본과 대조하는 법
-- ---------------------------------------------------------------------------
-- 같은 프로브를 **일본 원본 디스크**에도 돌려라.  원본에서는 헬퍼 카운트가 0 이고
-- 프레임 분포만 나온다.  두 분포가 같으면 버벅임은 원래 게임 것이다.
--
--   NTSC 한 프레임 = masterClock 약 357,366 (21.47727 MHz / 60.0988)
--
--   Script -> Settings -> Restrictions -> Allow I/O and OS

local mem = emu.memType.pceMemory
local HELPER_LO, HELPER_HI = 0xBCD2, 0xBFFF
local OVER = 380000            -- 이보다 크면 한 프레임을 넘긴 것

local stamp = "session"
if os ~= nil and os.date ~= nil then stamp = os.date("%Y%m%d_%H%M%S") end
local OUT = "C:\\snatcher\\dump\\probe_frame_cost_" .. stamp .. ".tsv"

local frame, lastClock, lastLog = 0, nil, 0
local helperThisFrame = 0
local rows = {}

-- 헬퍼 구간 실행.  명령 단위로 세면 비싸므로 진입점 몇 곳만 센다
local COUNT_AT = { 0xBD74, 0xBE23, 0xBDCE, 0xBE79 }   -- lookup · copy_record · load_package · load_blob
for _, addr in ipairs(COUNT_AT) do
  emu.addMemoryCallback(function()
    helperThisFrame = helperThisFrame + 1
  end, emu.callbackType.exec, addr, addr, emu.cpuType.pce, mem)
end

local withHelper = { n = 0, over = 0, sum = 0, max = 0 }
local without    = { n = 0, over = 0, sum = 0, max = 0 }

local function add(slot, delta)
  slot.n = slot.n + 1
  slot.sum = slot.sum + delta
  if delta > slot.max then slot.max = delta end
  if delta > OVER then slot.over = slot.over + 1 end
end

emu.addEventCallback(function()
  frame = frame + 1
  local ok, state = pcall(emu.getState)
  if ok and state ~= nil then
    local clock = state["masterClock"]
    if type(clock) == "number" then
      if lastClock ~= nil then
        local delta = clock - lastClock
        if delta > 0 then
          add(helperThisFrame > 0 and withHelper or without, delta)
          if delta > OVER then
            rows[#rows + 1] = string.format("%d\t%d\t%d", frame, delta, helperThisFrame)
          end
        end
      end
      lastClock = clock
    end
  end
  helperThisFrame = 0

  if frame - lastLog >= 900 then
    lastLog = frame
    local function pct(s) return s.n > 0 and 100 * s.over / s.n or 0 end
    emu.log(string.format(
      "%5.1f초  헬퍼 돈 프레임 %d (넘김 %.1f%%)  ·  안 돈 프레임 %d (넘김 %.1f%%)",
      frame / 60, withHelper.n, pct(withHelper), without.n, pct(without)))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  local file = io.open(OUT, "w")
  if file ~= nil then
    file:write("frame\tclock_delta\thelper_hits\n")
    for _, r in ipairs(rows) do file:write(r .. "\n") end
    file:close()
  end
  local function line(name, s)
    if s.n == 0 then return string.format("  %s  없음", name) end
    return string.format("  %-14s 프레임 %6d  넘김 %5d (%.1f%%)  평균 %.0f  최대 %d",
      name, s.n, s.over, 100 * s.over / s.n, s.sum / s.n, s.max)
  end
  emu.log(string.format("프레임 비용 %d 프레임 (%.1f초)", frame, frame / 60))
  emu.log(line("헬퍼 돈 것", withHelper))
  emu.log(line("헬퍼 안 돈 것", without))
  emu.log("  -> " .. OUT)
  if withHelper.n > 0 and without.n > 0 then
    local a = 100 * withHelper.over / withHelper.n
    local b = 100 * without.over / without.n
    if a > b * 2 then
      emu.log("  ★ 헬퍼가 돈 프레임이 훨씬 많이 넘친다 -- 버벅임은 우리 몫이다")
    else
      emu.log("  ★ 두 쪽이 비슷하다 -- 버벅임은 우리가 만든 것이 아니다")
    end
  end
end, emu.eventType.scriptEnded)

emu.log("PROBE 프레임 비용 0.1.0 -- 버벅이는 구간을 지나고 Stop")
emu.log("  -> " .. OUT)
