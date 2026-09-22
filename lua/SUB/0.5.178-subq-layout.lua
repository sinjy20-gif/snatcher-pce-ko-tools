-- SUB 0.5.178 -- CD_SUBQ 열 바이트 중 **어디가 M:S:F 인가** 를 가린다
--
-- ★ 순수 관측.  아무것도 안 쓴다.  화면에도 아무것도 안 그린다.
--
-- 0.5.177 과 무엇이 다른가
-- ------------------------
-- 0.5.177 은 1 초에 한 줄만 남겼다.  그런데 F(프레임)는 **초당 75 로 돈다.**
-- 60 프레임마다 찍으면 별칭(aliasing)이 생겨 F 를 못 가린다.
-- 그래서 이 판은 **연속 프레임 폭주 구간**을 둔다 -- 트랙이 돌기 시작하면
-- 240 프레임(4 초)을 한 프레임도 빠짐없이 남긴다.  그 표를 보면
--
--     4 초 동안 300 번쯤 오르고 75 마다 0 으로 도는 바이트   = F
--     그 위에서 4 번 오르는 바이트                          = S
--     안 변하는 바이트                                      = M (짧은 구간이라)
--
-- 가 한눈에 갈린다.
--
-- 왜 이걸 재나 -- 드리프트를 고치려고
-- -----------------------------------
-- 스케줄러는 `INC S_ELAPSED` 로 **호출당 1** 을 센다.  즉 elapsed 는 시간이
-- 아니라 "내가 몇 번 불렸나" 다.  프레임을 건너뛰면 자막 시계가 멈추고 그게
-- 쌓인다 (정상 속도에서 뒤로 갈수록 밀린다.  오버클럭에서는 안 나타난다
-- -- 소유자 2026-09-05 실측).
--
-- 고치는 법은 문서에 이미 있다:
--     docs/handoff/SNATCHER_CUTSCENE_SUBS_2026-08-19.md:343
--       "VSync 프레임 카운터 + CD_SUBQ 의 M:S:F 로 재동기   드리프트 0"
-- CD-DA 는 75 섹터/초짜리 하드웨어 시계다.  그걸 읽으면 몇 번 불렸든 무관하다.
--
-- 알아야 할 것 둘
--     ① M:S:F 가 $20A0-$20A9 중 어디인가        <- 폭주 구간이 답한다
--     ② 게임이 SUBQ 를 얼마나 자주 새로 뜨나     <- "얼어 있던 프레임" 이 답한다
--        (결과는 $6119 직후에만 유효하다고 문서에 적혀 있다.  그 주기가
--         재동기 주기를 정한다)
--
-- 아는 것 (여기서 다시 확인만 한다)
--     $20A0  상태 (2 = 재생 중).  PCE zp 가 $2000-$20FF 이므로 곧 zp $A0
--     $20A2  트랙 BCD.  스케줄러가 정지 검사에 이미 쓴다
--
-- 산출물  C:/snatcher/dump/subq_layout_0_5_178_<시각>.tsv
--         kind=BURST 가 연속 프레임 · kind=BEAT 가 1 초 간격

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/subq_layout_0_5_178_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tkind\tsched\tstate\tb0\tb1\tb2\tb3\tb4\tb5\tb6\tb7\tb8\tb9\n')

local function say(m) emu.log(m); print(m) end

local SUBQ  = 0x20A0
local SCHED = 0xECF9
local ENG   = 0x5B80
local READY, COUNT, TRACKBCD = ENG + 326, ENG + 330, ENG + 660

local BURST_FRAMES = 240        -- 4 초.  F 가 75 마다 도는 것을 보기에 충분하다

local frame, sched = 0, 0
local bank1 = false
local armed_at = nil
local burst_left = 0
local burst_done = false
local last, frozen, frozen_max, changes = nil, 0, 0, 0

emu.addMemoryCallback(function() bank1 = true end,
                      emu.callbackType.exec, 0xFFD4, 0xFFD4, CPU, MEM)
emu.addMemoryCallback(function() bank1 = false end,
                      emu.callbackType.exec, 0xF050, 0xF050, CPU, MEM)

emu.addMemoryCallback(function()
  if not bank1 then return end
  sched = sched + 1
  if not armed_at then
    armed_at = frame
    burst_left = BURST_FRAMES          -- 무장하자마자 폭주 구간을 연다
    say(('★스케줄러 첫 호출  f%d  -- 여기서 %d 프레임 연속 기록'):format(frame, BURST_FRAMES))
  end
end, emu.callbackType.exec, SCHED, SCHED, CPU, MEM)

local function subq()
  local b = {}
  for i = 0, 9 do b[i] = emu.read(SUBQ + i, MEM, false) or -1 end
  return b
end

local function same(a, b)
  if not a or not b then return false end
  for i = 0, 9 do if a[i] ~= b[i] then return false end end
  return true
end

local function row(kind, b)
  out:write(('%d\t%s\t%d\t%02X\t%02X\t%02X\t%02X\t%02X\t%02X\t%02X\t%02X\t%02X\t%02X\t%02X\n')
    :format(frame, kind, sched, emu.read(0x7FDF, MEM, false) or -1,
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9]))
end

emu.addEventCallback(function()
  frame = frame + 1
  local b = subq()

  if same(b, last) then
    frozen = frozen + 1
    if frozen > frozen_max then frozen_max = frozen end
  else
    if last then changes = changes + 1 end
    frozen = 0
    last = b
  end

  -- ① 폭주: 무장 직후 240 프레임을 한 줄도 빠짐없이
  if burst_left > 0 then
    row('BURST', b)
    burst_left = burst_left - 1
    if burst_left == 0 then
      burst_done = true
      out:flush()
      say('  폭주 구간 끝 -- 이제 1 초 간격으로 남긴다')
    end
  elseif frame % 60 == 0 then
    row('BEAT', b)
    out:flush()
  end

  if frame % 900 == 0 then
    local since = armed_at and (frame - armed_at) or 0
    say(('심박 f%-7d sched=%-6d 무장후=%-6d 뒤처짐=%-5d (%.2f s)  '
      .. 'trk=%02X ready=%02X count=%02X  subq %02X %02X %02X %02X %02X %02X %02X %02X')
      :format(frame, sched, since, since - sched, (since - sched) / 60.0,
              emu.read(TRACKBCD, MEM, false) or -1,
              emu.read(READY, MEM, false) or -1,
              emu.read(COUNT, MEM, false) or -1,
              b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8]))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  say('')
  say('끝')
  local since = armed_at and (frame - armed_at) or 0
  local lines = {
    ('  전체 프레임          %d'):format(frame),
    ('  스케줄러 첫 호출     f%s'):format(armed_at and tostring(armed_at) or '(없음)'),
    ('  무장 뒤 프레임       %d'):format(since),
    ('  스케줄러 호출        %d'):format(sched),
    ('  ★뒤처짐             %d 프레임 = %.2f 초'):format(since - sched, (since - sched) / 60.0),
    ('  폭주 구간            %s'):format(burst_done and '기록됨' or '★못 열었다 (무장을 못 봤다)'),
    ('  SUBQ 가 바뀐 횟수    %d'):format(changes),
    ('  SUBQ 최장 정지       %d 프레임 (%.2f 초)  <- 재동기 주기의 하한')
      :format(frozen_max, frozen_max / 60.0),
  }
  out:write('#\n')
  for _, l in ipairs(lines) do say(l); out:write('# ' .. l .. '\n') end
  out:close()
  say('')
  say('  읽는 법 -- BURST 줄만 보고, 4 초 동안')
  say('    300 번쯤 오르고 75 에서 0 으로 도는 열   = F')
  say('    4 번 오르는 열                          = S')
  say('    안 변하는 열                            = M (또는 안 쓰는 자리)')
  say('  ' .. PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.178-subq-layout armed -- 순수 관측 (★0.5.3 에 올릴 것)')
say('  오프닝 CD-DA 를 틀고 30 초쯤 두면 된다 (폭주 구간은 무장 직후 4 초)')
say('  ' .. PATH)
