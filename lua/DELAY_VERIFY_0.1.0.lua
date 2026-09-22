-- 지연 검증 0.1.0 -- **계측기부터 검증한다.**  지연이 실제로 시간을 쓰는가
--
-- 왜 이걸 먼저 하나
-- ---------------------------------------------------------------------------
-- DELAY_SWEEP_0.2.1 이 낸 표가 이랬다 (2026-08-18 22:01):
--
--     value  calls  samples   <8    8-13  >40   worst
--     0       48    5269     1769   2063  1436  79.2
--     72      73    5269     1779   2053  1436  79.2
--
-- `samples` 가 전 구간 **정확히 5269**, `>40` 도 **정확히 1436**.
--
-- 지연 72 는 호출마다 245 라인을 먹는다.  8 초에 73 회 호출이면 480 프레임 중
-- 68 프레임(14%)을 CPU 가 멈춰 있어야 하고, 그동안 게임은 스크롤 쓰기를 못 하니
-- samples 가 눈에 띄게 줄어야 한다.  한 자리도 안 움직였다.
--
-- 그러면 둘 중 하나다.
--     (가) 지연 루프가 실제로는 안 돈다 -- 바이트는 바뀌었는데 실행이 안 된다
--     (나) 내 산정이 틀렸다 -- 245 라인이 아니라 훨씬 싸다
--
-- 구워서 고정한 0.4.6-delay72 에서는 소유자가 "확실히 더 심해졌다" 고 했다.
-- 같은 지연인데 결과가 갈리므로 (가) 가 유력하다.  **추측하지 말고 센다.**
--
-- 무엇을 세나 -- 셋 다 직접 관측이다
-- ---------------------------------------------------------------------------
--     iters      $BE5B(render_delay_outer) 실행 횟수.  n=72 면 호출당 72 여야 한다
--                0 이면 루프에 진입조차 안 한 것 -> (가) 확정
--     byte       $BE63 에 도달한 시점에 CPU 가 보는 $BE58 의 값
--                우리가 쓴 값과 다르면 emu.write 가 실행에 안 먹히는 것
--     occupancy  $BCD2 진입 -> $BE63 도달 사이의 cpu.cycleCount 차이 (라인 환산)
--                n=0 이면 ~12 라인, n=72 면 ~255 라인이어야 한다
--
-- 이 셋이 맞아떨어지면 계측기가 정상이고, 그때 비로소 스윕 결과를 믿을 수 있다.
--
-- 헬퍼 지연 루프 배치 (helper_symbols.json 실측)
-- ---------------------------------------------------------------------------
--     BE57  A0 nn     LDY #n        <- nn 이 $BE58
--     BE59  F0 08     BEQ $BE63     n=0 이면 통째로 건너뛴다
--     BE5B  A2 00     LDX #0        <- 바깥 루프.  여기를 센다
--     BE5D  CA        DEX           <- 안쪽 256 회.  훅 걸면 안 된다 (너무 잦다)
--     BE5E  D0 FD     BNE $BE5D
--     BE60  88        DEY
--     BE61  D0 F8     BNE $BE5B
--     BE63  48        PHA           <- 지연 끝
--
-- 쓰는 법
-- ---------------------------------------------------------------------------
--   디스크  build\patch\0.4.7-delayslot\...(0818-2130).cue
--   폐공장일 필요 없다.  **메뉴를 계속 열었다 닫았다** 하기만 하면 된다
--   (헬퍼가 돌아야 재진다).  3 초씩 0 <-> 72 를 네 번 왕복 = 약 25 초.
--   그 뒤 정지.
--
--   출력: C:\snatcher\dump\delay_verify_0_1_0.tsv

local OUT = "C:\\snatcher\\dump\\delay_verify_0_1_0.tsv"
local mem = emu.memType.pceMemory

local HELPER = 0xBCD2          -- 헬퍼 진입
local LOOP   = 0xBE5B          -- 바깥 루프 진입.  n 번 찍혀야 한다
local DONE   = 0xBE63          -- 지연 끝 (PHA)
local SLOT   = 0xBE58          -- 지연 횟수 즉치 바이트

local CYCLES_PER_LINE = 455.0
local HOLD = 180               -- 3 초
local VALUES = { 0, 72, 0, 72, 0, 72, 0, 72 }

local file = assert(io.open(OUT, "w"))
file:write("kind\tframe\twant\tcalls\titers\titers_per_call\tbyte_seen\tocc_avg\tocc_max\tnote\n")

local frame, step, stepFrame = 0, 1, 0
local want, writes = VALUES[1], 0

local calls, iters, occSum, occMax, byteSeen = 0, 0, 0, 0, -1
local entryCycle = nil
local results = {}

local function cycles()
  local ok, state = pcall(emu.getState)
  if not ok or state == nil then return nil end
  return state["cpu.cycleCount"]
end

local function row(kind, note)
  local per = (calls > 0) and (iters / calls) or 0
  local avg = (calls > 0) and (occSum / calls) or 0
  file:write(string.format("%s\t%d\t%d\t%d\t%d\t%.1f\t%d\t%.1f\t%.1f\t%s\n",
    kind, frame, want, calls, iters, per, byteSeen, avg, occMax, note or ""))
  file:flush()
end

local function resetBucket()
  calls, iters, occSum, occMax, byteSeen = 0, 0, 0, 0, -1
  entryCycle = nil
end

emu.addMemoryCallback(function()
  calls = calls + 1
  if emu.read(SLOT, mem) ~= want then
    emu.write(SLOT, want, mem)
    writes = writes + 1
  end
  entryCycle = cycles()
end, emu.callbackType.exec, HELPER, HELPER, emu.cpuType.pce, mem)

-- 바깥 루프 한 바퀴마다 한 번.  n=72 면 호출당 72 번이어야 한다
emu.addMemoryCallback(function()
  iters = iters + 1
end, emu.callbackType.exec, LOOP, LOOP, emu.cpuType.pce, mem)

emu.addMemoryCallback(function()
  -- CPU 가 실제로 보고 있는 바이트.  우리가 쓴 값과 같아야 한다
  byteSeen = emu.read(SLOT, mem)
  if entryCycle ~= nil then
    local now = cycles()
    if now ~= nil then
      local lines = (now - entryCycle) / CYCLES_PER_LINE
      if lines > 0 and lines < 2000 then
        occSum = occSum + lines
        if lines > occMax then occMax = lines end
      end
    end
    entryCycle = nil
  end
end, emu.callbackType.exec, DONE, DONE, emu.cpuType.pce, mem)

emu.addEventCallback(function()
  frame = frame + 1
  stepFrame = stepFrame + 1
  if stepFrame == 1 then
    want = VALUES[step]
    resetBucket()
  end
  if stepFrame >= HOLD then
    row("bucket", string.format("구간 %d/%d", step, #VALUES))
    results[#results + 1] = { want, calls, iters, byteSeen, occSum, occMax }
    step = step % #VALUES + 1
    stepFrame = 0
  end

  local per = (calls > 0) and (iters / calls) or 0
  local avg = (calls > 0) and (occSum / calls) or 0
  emu.drawString(4, 4, string.format("want %3d · 헬퍼 %d 회 · 루프 %d (호출당 %.1f)",
    want, calls, iters, per), 0xFFFFFF, 0x80000000, 1)
  emu.drawString(4, 14, string.format("CPU 가 본 바이트 %d · 점유 평균 %.1f 라인 (최대 %.1f)",
    byteSeen, avg, occMax), 0xC0C0C0, 0x80000000, 1)
  if calls == 0 then
    emu.drawString(4, 24, "★ 메뉴를 열었다 닫았다 하세요", 0xFF6060, 0x80000000, 1)
  elseif want > 0 and iters == 0 then
    emu.drawString(4, 24, "★ 루프 0 회 -- 지연이 실행되지 않는다 (이게 답이다)",
      0xFF6060, 0x80000000, 1)
  else
    emu.drawString(4, 24, "정상 계측 중", 0x80FF80, 0x80000000, 1)
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  row("final", "정지 시점")
  file:write("\n-- 구간 요약 --\n")
  file:write("want\tcalls\titers\titers_per_call\tbyte_seen\tocc_avg\tocc_max\n")
  for _, r in ipairs(results) do
    file:write(string.format("%d\t%d\t%d\t%.1f\t%d\t%.1f\t%.1f\n",
      r[1], r[2], r[3], (r[2] > 0) and (r[3] / r[2]) or 0, r[4],
      (r[2] > 0) and (r[5] / r[2]) or 0, r[6]))
  end
  file:write(string.format("\n-- 쓰기 %d 회\n", writes))
  file:write("-- 판정: want 72 인 구간에서 iters_per_call 이 72 면 계측기 정상,\n")
  file:write("--       0 이면 지연이 실행되지 않는 것이고 스윕 결과는 전부 무효다\n")
  file:close()
end, emu.eventType.scriptEnded)

emu.log("지연 검증 0.1.0 -- 지연이 실제로 시간을 쓰는지부터 센다")
emu.log("  3 초씩 0 <-> 72 왕복.  메뉴만 계속 열었다 닫았다 하면 된다 (약 25 초)")
emu.log("  want 72 에서 호출당 루프가 72 면 정상 · 0 이면 지연이 안 도는 것")
emu.log("  출력: " .. OUT)
