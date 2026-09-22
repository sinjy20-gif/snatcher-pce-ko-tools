-- SUB 0.5.177 -- CD-DA 자막이 뒤로 갈수록 밀리는 이유를 잰다
--
-- ★ 순수 관측.  아무것도 안 쓴다.  화면에도 아무것도 안 그린다.
--
-- 왜
-- --
-- 0.5.1 실기에서 CD-DA 자막이 **처음엔 1 초쯤 늦고, 뒤로 갈수록 더 늦어진다.**
-- 상수 오프셋이 아니라 누적 드리프트다.
--
-- 짐작되는 원인은 이미 데이터가 가리키고 있다.  0.5.176 트레이스에서
-- 스케줄러 호출 횟수가 실제 프레임보다 **적었고, 갈수록 더 벌어졌다**:
--
--     f6300->7200   프레임 900   호출 895   0.994
--     f7200->8100          900       855   0.950
--     f9900->10800         900       843   0.937
--     f11700->12600        900       811   0.901   <- 갈수록 나빠진다
--     합계        프레임 6300   호출 6038   262 프레임(4.4 초) 누락
--
-- 스케줄러는 `INC S_ELAPSED` 로 **호출당 1** 을 센다.  그래서 빠뜨린 프레임만큼
-- 자막이 뒤로 밀리고, 그게 쌓인다.
--
-- 고치는 방향도 이미 문서에 있다 (풀어놓고 이식만 안 한 건이다)
-- ------------------------------------------------------------
--     docs/handoff/SNATCHER_CUTSCENE_SUBS_2026-08-19.md:343
--       "VSync 프레임 카운터 + CD_SUBQ 의 M:S:F 로 재동기   드리프트 0"
--     docs/handoff/SNATCHER_NATIVE_SUBTITLE_BASELINE_2026-08-30.md:46
--       "중간 프레임은 VSync 로 보간한 뒤 주기적으로 SUBQ 에 재동기한다"
--
-- CD-DA 는 75 섹터/초짜리 **하드웨어 시계**다.  프레임을 세는 대신 그 시계를
-- 읽으면 드리프트가 원리적으로 0 이 된다.
--
-- 그래서 이 프로브가 답해야 할 것 셋
-- ----------------------------------
--     ① $20A0-$20A9 열 바이트 중 **어디가 M:S:F 인가**
--        ($20A0 = 상태(2=재생중) · $20A2 = 트랙 BCD 는 이미 안다.
--         나머지는 이름만 알고 실물로 확인한 적이 없다)
--     ② 그 값이 **매 프레임 살아 있나**  -- CD_SUBQ 결과는 지속 상태가 아니라
--        `$6119` 직후에만 유효하다고 문서에 적혀 있다.  게임이 얼마나 자주
--        새로 뜨는지에 따라 재동기 주기가 정해진다
--     ③ 스케줄러 호출 횟수가 CD 시계보다 얼마나 뒤처지나 (드리프트 실측)
--
-- 읽는 법
-- -------
--     b3..b9 중 75 마다 0 으로 도는 바이트  = F (프레임, BCD)
--     그 위에서 1 초마다 오르는 바이트      = S
--     그 위                                  = M
--     같은 값이 여러 프레임 얼어 있으면      = 게임이 그동안 SUBQ 를 안 떴다
--     sched 열이 frame 열보다 적으면         = 그만큼 자막이 밀린다 ★
--
-- 산출물  C:/snatcher/dump/subq_drift_0_5_177_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/subq_drift_0_5_177_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tsched\tstate\tb0\tb1\tb2\tb3\tb4\tb5\tb6\tb7\tb8\tb9\tnote\n')

local function say(m) emu.log(m); print(m) end

local SUBQ = 0x20A0          -- CD_SUBQ 결과 10 B (= zp $A0)
local SCHED = 0xECF9         -- scheduler_cdda
local ENG = 0x5B80
local READY = ENG + 326
local COUNT = ENG + 330
local TRACKBCD = ENG + 660

local frame = 0
local sched = 0
local bank1 = false
local armed_at = nil         -- 스케줄러가 처음 돈 프레임
local last = nil             -- 직전 10 B (변화 감지용)
local frozen = 0             -- 값이 안 바뀐 연속 프레임
local frozen_max = 0
local changes = 0

-- ⚠ MPR7 이 뱅크 $00 이면 같은 주소가 원본 시스템카드다 (0.5.172 의 함정).
--   창을 세서 뱅크 $01 인 동안의 접촉만 센다.
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
    out:write(('%d\t%d\t\t\t\t\t\t\t\t\t\t\tSCHED_FIRST\n'):format(frame, sched))
    out:flush()
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

local function row(b, note)
  local st = emu.read(0x7FDF, MEM, false) or -1
  out:write(('%d\t%d\t%02X\t%02X\t%02X\t%02X\t%02X\t%02X\t%02X\t%02X\t%02X\t%02X\t%02X\t%s\n')
    :format(frame, sched, st,
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], note or ''))
end

emu.addEventCallback(function()
  frame = frame + 1
  local b = subq()

  -- ① 값이 얼마나 자주 새로 뜨나
  if same(b, last) then
    frozen = frozen + 1
    if frozen > frozen_max then frozen_max = frozen end
  else
    if frozen > 0 and last then changes = changes + 1 end
    frozen = 0
    last = b
  end

  -- ② 1 초에 한 줄씩 남긴다 (트랙이 도는 동안만)
  if b[2] ~= 0x00 and frame % 60 == 0 then
    row(b, '')
    out:flush()
  end

  -- ③ 심박 -- 드리프트를 바로 읽을 수 있게 같이 찍는다
  if frame % 900 == 0 then
    local since = armed_at and (frame - armed_at) or 0
    local lag = since - sched
    say(('심박 f%-7d sched=%-6d 무장후=%-6d 뒤처짐=%-5d (%.2f s)  '
      .. 'trk=%02X ready=%02X count=%02X  subq=%02X %02X %02X %02X %02X %02X %02X')
      :format(frame, sched, since, lag, lag / 60.0,
              emu.read(TRACKBCD, MEM, false) or -1,
              emu.read(READY, MEM, false) or -1,
              emu.read(COUNT, MEM, false) or -1,
              b[2], b[3], b[4], b[5], b[6], b[7], b[8]))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  say('')
  say('끝 -- 드리프트 실측')
  local since = armed_at and (frame - armed_at) or 0
  local lag = since - sched
  local lines = {
    ('  전체 프레임        %d'):format(frame),
    ('  스케줄러 첫 호출   f%s'):format(armed_at and tostring(armed_at) or '(없음)'),
    ('  무장 뒤 프레임     %d'):format(since),
    ('  스케줄러 호출      %d'):format(sched),
    ('  ★뒤처짐           %d 프레임 = %.2f 초'):format(lag, lag / 60.0),
    ('  SUBQ 값이 바뀐 횟수 %d'):format(changes),
    ('  SUBQ 가 가장 오래 얼어 있던 구간 %d 프레임 (%.2f 초)')
      :format(frozen_max, frozen_max / 60.0),
  }
  out:write('#\n')
  for _, l in ipairs(lines) do say(l); out:write('# ' .. l .. '\n') end
  out:close()
  say('')
  if lag > 30 then
    say('  ★드리프트 확인.  elapsed 를 프레임 세기 대신 SUBQ M:S:F 로 재동기할 것')
  end
  say('  ' .. PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.177-subq-drift armed -- 순수 관측 (★0.5.1 에 올릴 것)')
say('  오프닝 CD-DA 를 자막이 눈에 띄게 밀릴 때까지 (2 분쯤) 틀어두면 된다')
say('  ' .. PATH)
