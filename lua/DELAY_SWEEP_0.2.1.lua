-- 지연 스윕 0.2.1 -- 밀림을 숫자로 잰다.  0.2.0 의 계측 고장을 고친 판
--
-- 0.2.0 은 무엇이 고장났나
-- ---------------------------------------------------------------------------
-- 위치를 `scanline` 이 들어간 키로 찾게 해뒀더니 `vce.scanlineCount` 가 잡혔다.
-- 그건 **현재 스캔라인이 아니라 총 스캔라인 수**(262 같은 상수)다.  그래서
-- 간격이 늘 0 이었고 실측이 이렇게 나왔다:
--
--     gaps 0 · late 0 · worst 0.0   -- 전 구간 동일
--
-- 이건 "밀림이 없다" 가 아니라 **"아무것도 안 쟀다"** 이다.  결과로 쓰면 안 된다.
-- 같은 실행에서 `cpu.cycleCount` 는 정상으로 잡혔으므로 그것만 쓴다.
--
--     1 스캔라인 = 7.16 MHz / (262 x 60) ~= 455 cycle
--
-- 그리고 이번엔 임계값을 미리 정하지 않는다.  0.2.0 은 "14 줄 넘으면 밀린 것"
-- 이라고 내가 정해놓고 셌는데, 실제 간격 분포를 본 적이 없으므로 근거가 없었다.
-- **분포를 통째로 낸다.**  임계는 분포를 보고 나서 정한다.
--
-- 무엇을 세나
-- ---------------------------------------------------------------------------
--     samples   스크롤 갱신($43F7)이 들어온 횟수
--     분포      갱신 간격을 줄 단위로 구간별 집계 (<8 / 8-13 / 14-20 / 21-40 / >40)
--     worst     그 구간에서 가장 길었던 간격
--     overlap   헬퍼가 도는 중에 갱신이 들어온 횟수 (직접 충돌)
--     calls     헬퍼가 돈 횟수.  0 이면 그 구간은 비교 대상이 아니다
--
-- 점유 모형이 맞으면 지연을 키울수록 **긴 간격 쪽으로 분포가 밀려야** 한다.
-- 분포가 값과 무관하게 같으면 모형이 죽는다.  어느 쪽이든 표로 남는다.
--
-- 쓰는 법
-- ---------------------------------------------------------------------------
--   디스크  build\patch\0.4.7-delayslot\...(0818-2130).cue
--   ★ 폐공장 화면에 머물 것.  화면이 바뀌면 갱신 패턴이 달라져 비교가 깨진다
--   ★★ 가만히 있으면 안 된다.  헬퍼는 글자를 그릴 때만 돈다.
--      **액션 메뉴를 계속 열었다 닫았다** 할 것.  화면의 `헬퍼 N 회` 가 올라가야 한다
--   8 초 x 8 구간 = 약 1 분.  한 바퀴 돌면 정지.
--
--   출력: C:\snatcher\dump\delay_sweep_0_2_1.tsv
--         파일 첫머리에 emu.getState() 의 키 후보를 통째로 적는다 -- 다음에
--         또 엉뚱한 키를 고르지 않기 위한 것이다

local OUT = "C:\\snatcher\\dump\\delay_sweep_0_2_1.tsv"
local mem = emu.memType.pceMemory

local HELPER = 0xBCD2
local RETURN = 0xBE57
local SLOT   = 0xBE58
local LINES_PER_UNIT = 3.4
local CYCLES_PER_LINE = 455.0

local SCROLL_WRITE = 0x43F7    -- 여섯 쓰기 중 대표 하나 (간격 = 밴드 간격)

local HOLD = 480               -- 값 하나당 8 초
local VALUES = { 0, 4, 12, 36, 72, 0, 144, 0 }

local file = assert(io.open(OUT, "w"))

-- 위치는 사이클로만 읽는다.  이름으로 고르지 않고 이 키 하나를 박아 쓴다
local CYCLE_KEY = "cpu.cycleCount"

do  -- 다음 판을 위해 키 목록을 남긴다.  추측을 반복하지 않기 위한 기록이다
  local ok, state = pcall(emu.getState)
  local names = {}
  if ok and type(state) == "table" then
    for key, value in pairs(state) do
      if type(value) == "number" then names[#names + 1] = key end
    end
    table.sort(names)
  end
  file:write("-- emu.getState() 숫자 키 " .. #names .. " 개\n-- ")
  file:write(table.concat(names, " ") .. "\n")
  file:write("-- 쓰는 키: " .. CYCLE_KEY .. " (1 라인 = "
             .. CYCLES_PER_LINE .. " cycle)\n\n")
end

local function cycles()
  local ok, state = pcall(emu.getState)
  if not ok or state == nil then return nil end
  return state[CYCLE_KEY]
end

file:write("kind\tframe\tvalue\tlines\tcalls\tsamples\tgaps\t<8\t8-13\t14-20\t21-40\t>40\tworst\toverlap\tnote\n")

local frame, step, stepFrame = 0, 1, 0
local want, applied, writes = VALUES[1], -1, 0
local inHelper = false

local calls, samples, gaps, worst, overlap = 0, 0, 0, 0, 0
local dist = { 0, 0, 0, 0, 0 }         -- <8 / 8-13 / 14-20 / 21-40 / >40
local lastCycle = nil
local results = {}

local function bucketIndex(lines)
  if lines < 8 then return 1 end
  if lines < 14 then return 2 end
  if lines < 21 then return 3 end
  if lines < 41 then return 4 end
  return 5
end

local function row(kind, note)
  file:write(string.format(
    "%s\t%d\t%d\t%.0f\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%.1f\t%d\t%s\n",
    kind, frame, want, want * LINES_PER_UNIT, calls, samples, gaps,
    dist[1], dist[2], dist[3], dist[4], dist[5], worst, overlap, note or ""))
  file:flush()
end

local function resetBucket()
  calls, samples, gaps, worst, overlap = 0, 0, 0, 0, 0
  dist = { 0, 0, 0, 0, 0 }
  lastCycle = nil
end

emu.addMemoryCallback(function()
  inHelper = true
  calls = calls + 1
  if emu.read(SLOT, mem) ~= want then
    emu.write(SLOT, want, mem)
    writes = writes + 1
    applied = want
  end
end, emu.callbackType.exec, HELPER, HELPER, emu.cpuType.pce, mem)

emu.addMemoryCallback(function()
  inHelper = false
end, emu.callbackType.exec, RETURN, RETURN, emu.cpuType.pce, mem)

emu.addMemoryCallback(function()
  samples = samples + 1
  if inHelper then overlap = overlap + 1 end
  local now = cycles()
  if now == nil then return end
  if lastCycle ~= nil then
    local lines = (now - lastCycle) / CYCLES_PER_LINE
    -- 프레임을 넘어가면 간격이 한 프레임(262 줄)만큼 튄다.  그건 밀림이 아니다
    if lines > 0 and lines < 200 then
      gaps = gaps + 1
      dist[bucketIndex(lines)] = dist[bucketIndex(lines)] + 1
      if lines > worst then worst = lines end
    end
  end
  lastCycle = now
end, emu.callbackType.exec, SCROLL_WRITE, SCROLL_WRITE, emu.cpuType.pce, mem)

emu.addEventCallback(function()
  frame = frame + 1
  stepFrame = stepFrame + 1

  if stepFrame == 1 then
    want = VALUES[step]
    resetBucket()
  end

  if stepFrame >= HOLD then
    row("bucket", string.format("구간 %d/%d 끝", step, #VALUES))
    results[#results + 1] = { want, calls, samples, gaps,
                              dist[1], dist[2], dist[3], dist[4], dist[5],
                              worst, overlap }
    step = step % #VALUES + 1
    stepFrame = 0
  end

  local state = (applied == want) and "적용" or "대기"
  emu.drawString(4, 4, string.format("지연 %3d = %3.0f 라인 [%s]  %ds",
    want, want * LINES_PER_UNIT, state, math.ceil((HOLD - stepFrame) / 60)),
    0xFFFFFF, 0x80000000, 1)
  emu.drawString(4, 14, string.format("간격 <8:%d  8-13:%d  14-20:%d  21-40:%d  >40:%d",
    dist[1], dist[2], dist[3], dist[4], dist[5]), 0xC0C0C0, 0x80000000, 1)
  if calls == 0 then
    emu.drawString(4, 24, "★ 헬퍼 0 회 -- 메뉴를 열었다 닫았다 하세요",
      0xFF6060, 0x80000000, 1)
  else
    emu.drawString(4, 24, string.format("헬퍼 %d 회 · 겹침 %d · 최악 %.0f줄",
      calls, overlap, worst), 0x80C0FF, 0x80000000, 1)
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  row("final", "정지 시점")
  file:write("\n-- 구간 요약 (같은 화면, 값만 다름).  긴 간격 쪽으로 밀리는지 볼 것 --\n")
  file:write("value\tlines\tcalls\tsamples\tgaps\t<8\t8-13\t14-20\t21-40\t>40\tworst\toverlap\n")
  for _, r in ipairs(results) do
    file:write(string.format("%d\t%.0f\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%.1f\t%d%s\n",
      r[1], r[1] * LINES_PER_UNIT, r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9],
      r[10], r[11], (r[2] == 0) and "   <- 헬퍼 0 회.  비교에서 뺄 것" or ""))
  end
  file:write(string.format("\n-- 쓰기 %d 회\n", writes))
  file:close()
end, emu.eventType.scriptEnded)

emu.log("지연 스윕 0.2.1 -- 0.2.0 은 vce.scanlineCount(상수)를 잡아 아무것도 못 쟀다")
emu.log("  이번엔 cpu.cycleCount 로 잰다.  임계값을 안 정하고 분포를 통째로 낸다")
emu.log("  ★ 폐공장에서 **메뉴를 계속 열었다 닫았다** 할 것.  8 초 x 8 = 약 1 분")
emu.log("  출력: " .. OUT)
