-- 0.7.0-ram-slot -- 워킹 RAM $5B80 을 누가 언제 쓰는지 본다
--
--   덤프: snatcher_tool/logs/cost_v070.tsv   ★프로브와 같은 판번호
--   아직 한 번도 안 돌렸다.
--
-- 화면에는 아무것도 안 그린다.
--
-- 왜 이 프로브가 필요한가
-- ------------------------
-- 0.3.0 은 ADPCM 경로 일곱 군데에만 브레이크를 걸어서, ADPCM 이 아닌
-- 것(대사 등)은 로그에 아예 안 남았다. "자막만 나온 것 같다"는 그 때문이다.
-- 그리고 같은 이유로 ③ -- 엔진을 $5B80 에 올리는 복사 -- 도 못 봤다.
--
-- 0.3.0 실측으로 확정된 것:
--   $FC7A 대피 시점  $5B80 = 게임 데이터 (53 24 80 B1 81 0A 등)
--   $FCDF 복귀 시점  $5B80 = 엔진        (00 55 42 AD 30 5D)
-- 그 사이에 누군가 엔진을 써 넣었는데 BIOS 에는 $5B80 에 쓰는 코드가
-- $FD00(복귀 루프) 하나뿐이다. 즉 헬퍼(AC $1F1C00, 디스크 쪽)가 한다.
--
-- 그래서 코드 주소가 아니라 **메모리 쓰기**를 잡는다. 누가 쓰든 걸린다.
--
-- 무엇을 답하나
--   · ③ 이 대사마다 실제로 일어나는가, 몇 cycle 인가
--   · 대사가 $5B80 을 실제로 도로 가져가는가 (가져간다면 그 흔적이 남는다)
--   · 671 B 복사 네 개 중 ①(재사용이 건너뛰는 것)이 전체의 몇 %인가
--
-- 읽는 법 -- 쓰기 버스트 한 덩어리가 한 줄이다
--   head6 가 005542AD305D  -> 엔진이 올라왔다  (③)
--   head6 가 그 밖의 값     -> 게임/대사 데이터가 돌아왔다 (④ 또는 대사)
--
-- 쓰는 법
--   1) 0.6.1 BIOS + [KO] CUE 로 Power Cycle.
--   2) 이 스크립트 하나만 켠다.
--   3) 자막 -> 대사 -> 자막 구간을 지난다.
--   4) ★ 반드시 Stop 한다.
--
-- 산출물  C:/snatcher/dump/ram_slot_0_4_0_<시각>.tsv

local VERSION = '0.7.0'
local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce
local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = "C:/snatcher/snatcher_tool/logs/cost_v070.tsv"

local MASTER_PER_CPU = 3
local CPU_HZ = 7159090
local FRAME_CYCLES = CPU_HZ / 60.0

-- 엔진 머리 6바이트. 0.3.0 이 복귀 시점에 실측한 값이다.
local ENGINE_HEAD = '005542AD305D'

-- 감시 창. $5B80 부터 6바이트만 본다. 671 B 복사 한 번에 6회 걸린다.
local LO, HI = 0x5B80, 0x5B85

-- 버스트 경계: 이만큼 CPU cycle 이상 벌어지면 다른 덩어리로 센다
local GAP = 2000

local out = assert(io.open(OUT, 'w'))
out:write('frame\tkind\twrites\tcpu_cycles\tms\tframe_pct\thead6\tnote\n')

local frame, rows = 0, 0
local bFirst, bLast, bCount, bFrame = nil, nil, 0, 0
local engineLoads, otherLoads = 0, 0
local engCyc, othCyc = 0, 0

local function clk()
  local ok, st = pcall(emu.getState)
  if not ok or type(st) ~= 'table' then return nil end
  return st.masterClock or st.MasterClock
end

local function rb(a) return emu.read(a, MEM) or 0 end

local function head6()
  local t = {}
  for i = 0, 5 do t[#t + 1] = string.format('%02X', rb(0x5B80 + i)) end
  return table.concat(t)
end

local function say(m) emu.log(m); print(m) end

local function flushBurst()
  if not bFirst then return end
  local cyc = (bLast - bFirst) / MASTER_PER_CPU
  local h = head6()
  local kind, note
  if h == ENGINE_HEAD then
    kind = 'ENGINE_IN'
    note = '③ 엔진이 $5B80 에 올라왔다'
    engineLoads = engineLoads + 1
    engCyc = engCyc + cyc
  else
    kind = 'DATA_IN'
    note = '게임/대사 데이터가 $5B80 에 들어왔다'
    otherLoads = otherLoads + 1
    othCyc = othCyc + cyc
  end
  out:write(string.format('%d\t%s\t%d\t%d\t%.3f\t%.1f%%\t%s\t%s\n',
    bFrame, kind, bCount, cyc, cyc / CPU_HZ * 1000,
    cyc / FRAME_CYCLES * 100, h, note))
  rows = rows + 1
  if rows % 16 == 0 then out:flush() end
  say(string.format('f%-7d %-10s writes=%-4d %7d cyc  %.2f ms  head=%s',
    bFrame, kind, bCount, cyc, cyc / CPU_HZ * 1000, h))
  bFirst, bLast, bCount = nil, nil, 0
end

emu.addMemoryCallback(function()
  local now = clk()
  if not now then return end
  if bFirst and (now - bLast) / MASTER_PER_CPU > GAP then
    flushBurst()
  end
  if not bFirst then
    bFirst = now
    bFrame = frame
    bCount = 0
  end
  bLast = now
  bCount = bCount + 1
end, emu.callbackType.write, LO, HI, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  -- 프레임 경계에서 열려 있는 버스트를 닫는다. 복사는 한 프레임 안에 끝난다.
  if bFirst then flushBurst() end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  flushBurst()
  say('')
  say(string.format('끝  프레임 %d', frame))
  say(string.format('  ③ 엔진 적재  %4d회   평균 %d cyc  %.3f ms  프레임의 %.1f%%',
    engineLoads, engineLoads > 0 and engCyc / engineLoads or 0,
    engineLoads > 0 and engCyc / engineLoads / CPU_HZ * 1000 or 0,
    engineLoads > 0 and engCyc / engineLoads / FRAME_CYCLES * 100 or 0))
  say(string.format('  그 밖의 적재 %4d회   평균 %d cyc',
    otherLoads, otherLoads > 0 and othCyc / otherLoads or 0))
  say('')
  if engineLoads == 0 then
    say('  ★ 엔진 적재를 한 번도 못 봤다. ADPCM 자막 구간을 지나지 않았거나')
    say('     엔진 머리가 ' .. ENGINE_HEAD .. ' 가 아니다. head6 칸을 직접 볼 것')
  else
    say('  ③ 은 ADPCM 자막마다 일어나야 한다. 자막 횟수와 대조할 것')
  end
  out:write('#\n')
  out:write(string.format('# frames=%d engine_loads=%d other_loads=%d\n',
    frame, engineLoads, otherLoads))
  out:close()
  say('-> ' .. OUT)
end, emu.eventType.scriptEnded)

say('COST ' .. VERSION .. ' ram-slot' .. ' -- 화면 표시 없음')
say('  $5B80-$5B85 쓰기를 잡는다. 코드 주소가 아니라 메모리라 누가 쓰든 걸린다')
say('  head6=' .. ENGINE_HEAD .. ' 이면 엔진, 아니면 데이터')
say('-> ' .. OUT)
