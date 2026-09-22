-- SUB 0.5.180 -- **진짜 프레임 카운터**를 RAM 에서 찾는다
--
-- ★ 순수 관측.  아무것도 안 쓴다.  화면에도 아무것도 안 그린다.
--
-- 왜
-- --
-- 스케줄러의 `elapsed` 는 `INC S_ELAPSED` 로 **호출당 1** 을 센다.  스케줄러는
-- 게임 루프(FEC4)에서 불리므로, 게임이 한 프레임을 넘기면 우리도 같이 건너뛴다.
-- 그러면 자막 시계가 멈추고 그게 쌓인다.
--
--     0.5.3 실측 (소유자, 2026-09-05)
--       f5400  뒤처짐  16 프레임
--       f9000          72
--       f11700        220  (3.67 초) -- 계속 벌어진다
--     ★오버클럭에서는 0 이다 = 프레임을 못 따라가서 생기는 문제다
--
-- 그런데 **VBlank 인터럽트는 CPU 가 밀려도 하드웨어가 계속 때린다.**  그러니
-- VBlank 에서 올라가는 카운터가 RAM 에 있다면 그것이 진짜 시계다.  스케줄러는
-- 그 값의 **차분**을 더하면 되고, 건너뛴 프레임까지 한꺼번에 따라잡는다.
--
--     지금    INC elapsed
--     바꾸면  LDA cnt / SBC last / ADC elapsed / STA elapsed / STA last
--
-- CD_SUBQ 를 직접 부르는 것보다 훨씬 싸고, 제로페이지 $20A0-$20A9 (게임도 쓰는
-- 자리)를 안 건드린다.
--
-- 어떻게 찾나
-- -----------
-- 매 프레임 8 KB 를 다 읽으면 느리다.  그래서 두 단계로 좁힌다.
--
--   1 차   RAM 을 두 시점에 통째로 떠서 **차이가 정확히 경과 프레임 수**인
--          바이트만 남긴다 (u8 은 mod 256, u16 쌍도 같이 본다).
--   2 차   후보만 매 프레임 읽어 **한 프레임에 정확히 +1** 인지 확인한다.
--          게임이 멈춘 프레임에도 오르는지가 핵심이다.
--
-- ⚠ 스케줄러 호출 수와 나란히 찍는다.  후보가 스케줄러보다 **더 많이** 올라야
--   쓸모가 있다 (같이 밀리면 지금과 다를 게 없다).
--
-- 산출물  C:/snatcher/dump/framecounter_0_5_180_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/framecounter_0_5_180_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))

local function say(m) emu.log(m); print(m) end

local RAM_LO, RAM_HI = 0x2000, 0x3FFF      -- PCE 워크 RAM 8 KB (제로페이지 포함)
local SCHED = 0xECF9
local SETTLE = 240                         -- 무장 뒤 이만큼 지나고 1 차 스냅
local GAP    = 600                         -- 1 차 두 스냅 사이 (10 초)
local WATCH  = 900                         -- 2 차 관찰 길이

local frame, sched = 0, 0
local bank1 = false
local armed_at = nil
local snapA, snapA_at = nil, nil
local cands = nil
local watch_from = nil
local prev = {}
local plus1, total, sched_at_start = {}, 0, 0

emu.addMemoryCallback(function() bank1 = true end,
                      emu.callbackType.exec, 0xFFD4, 0xFFD4, CPU, MEM)
emu.addMemoryCallback(function() bank1 = false end,
                      emu.callbackType.exec, 0xF050, 0xF050, CPU, MEM)

emu.addMemoryCallback(function()
  if not bank1 then return end
  sched = sched + 1
  if not armed_at then
    armed_at = frame
    say(('★스케줄러 첫 호출  f%d'):format(frame))
  end
end, emu.callbackType.exec, SCHED, SCHED, CPU, MEM)

local function snap()
  local t = {}
  for a = RAM_LO, RAM_HI do t[a] = emu.read(a, MEM, false) or 0 end
  return t
end

emu.addEventCallback(function()
  frame = frame + 1
  if not armed_at then return end

  -- 1 차 스냅 A
  if not snapA and frame == armed_at + SETTLE then
    snapA, snapA_at = snap(), frame
    say(('1 차 스냅 A  f%d'):format(frame))
    return
  end

  -- 1 차 스냅 B -> 후보 추리기
  if snapA and not cands and frame == snapA_at + GAP then
    local B = snap()
    local want = GAP % 256
    cands = {}
    for a = RAM_LO, RAM_HI do
      if (B[a] - snapA[a]) % 256 == want then cands[#cands + 1] = a end
    end
    say(('1 차 결과  %d 프레임 동안 정확히 그만큼 오른 바이트 %d 개')
      :format(GAP, #cands))
    if #cands == 0 then
      say('  ★없다.  게임이 프레임 카운터를 안 들고 있거나 이 구간 밖이다')
      out:write('# 후보 없음\n')
    end
    -- 2 차 준비
    watch_from = frame
    sched_at_start = sched
    out:write('# 후보 ' .. #cands .. ' 개\n')
    out:write('addr\tplus1\ttotal_frames\tsched_delta\tverdict\n')
    for _, a in ipairs(cands) do prev[a] = B[a]; plus1[a] = 0 end
    total = 0
    return
  end

  -- 2 차: 후보만 매 프레임 확인
  if cands and watch_from and frame > watch_from and frame <= watch_from + WATCH then
    total = total + 1
    for _, a in ipairs(cands) do
      local v = emu.read(a, MEM, false) or 0
      if (v - prev[a]) % 256 == 1 then plus1[a] = plus1[a] + 1 end
      prev[a] = v
    end
    if frame == watch_from + WATCH then
      local sd = sched - sched_at_start
      say('')
      say(('2 차 결과  %d 프레임 관찰 · 그동안 스케줄러 호출 %d 회 (뒤처짐 %d)')
        :format(total, sd, total - sd))
      say('  주소     +1 회수   판정')
      local best = {}
      for _, a in ipairs(cands) do
        local ok = plus1[a] >= total - 2          -- 거의 매 프레임 +1
        local verdict = ok and (plus1[a] > sd and '★진짜 시계 (스케줄러보다 많이 오른다)'
                                or '스케줄러와 같이 밀린다 -- 쓸모없다')
                            or '불규칙'
        out:write(('%04X\t%d\t%d\t%d\t%s\n'):format(a, plus1[a], total, sd, verdict))
        if ok then best[#best + 1] = { a, plus1[a], verdict } end
      end
      table.sort(best, function(x, y) return x[2] > y[2] end)
      for i = 1, math.min(#best, 12) do
        say(('  $%04X   %5d / %d   %s'):format(best[i][1], best[i][2], total, best[i][3]))
      end
      if #best == 0 then say('  ★매 프레임 +1 인 바이트가 없다') end
      out:flush()
    end
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:write('#\n')
  out:write(('# 전체 프레임 %d · 스케줄러 %d · 무장 f%s\n')
    :format(frame, sched, armed_at and tostring(armed_at) or '없음'))
  out:close()
  say('')
  say('  ' .. PATH)
  say('  ★"스케줄러보다 많이 오른다" 로 나온 주소가 쓸 수 있는 시계다')
end, emu.eventType.scriptEnded)

say('SUB 0.5.180-find-frame-counter armed -- 순수 관측 (★0.5.3 에 올릴 것)')
say('  오프닝 CD-DA 를 틀고 30 초쯤 두면 된다 (무장 뒤 4 초 + 10 초 + 15 초)')
say('  ' .. PATH)
