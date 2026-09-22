-- lua/COST/0.1.0-arm-count.lua   (옛 이름 PROBE_ARM_TRANSPORT_0_1_0.lua)
-- ★판번호는 COST 폴더 기준으로 다시 매겼다 (2026-09-05, 소유자 요청).
--   덤프 경로도 같이 바꿨다 -- 로그와 코드가 어긋나면 로그를 못 읽는다.
--   덤프: snatcher_tool/logs/cost_v010.tsv
--
-- PROBE_ARM_TRANSPORT 0.1.0 -- 671 B 를 **자막 하나마다** 정말 나르는가
--
-- 질문 (소유자, 2026-09-05)
-- ------------------------
--   "실제로 자막 하나마다 671B를 싣어 나르는지"
--
-- 정적으로는 이미 셌다 (tools/measure_arm_cost.py):
--
--   arm_copy_engine   AC -> AC  671 B  포트 루프   10,736 cyc   23.6 줄
--   precopy_cpu       TAI -> $5B80 671 B           4,043 cyc    8.9 줄
--   합계                                          15,203 cyc   33.4 줄
--
-- 그런데 **몇 번 도는지**는 코드를 읽어서 못 안다.  arm 이 클립마다인지,
-- 자막 줄마다인지, 아니면 상태가 안 바뀌는 동안 건너뛰는지는 실행이 정한다.
--
-- 무엇을 세나
-- -----------
--   $1A10 쓰기      AC 쓰기 포트.  엔진 복사가 여기로 671 B 를 밀어낸다
--                   한 프레임에 512 회 넘게 몰리면 그 프레임이 **적재 프레임**이다
--   $7FDF 쓰기      STATE.  arm 이 1 을 쓰고, resident_reset 이 0 을 쓴다
--                   0 -> 1 전이 수 = arm 횟수
--   $180D bit5      ADPCM 재생 중 플래그.  꺼짐 -> 켜짐 = 클립 시작
--
-- arm 횟수와 클립 수를 나란히 놓으면 답이 나온다.
--
--   arm == 클립      클립마다 671 B.  소유자 예상대로다
--   arm <  클립      어떤 클립은 건너뛴다 (resident_still 이 먹었다)
--   arm >  클립      자막 줄마다 돈다.  제일 나쁜 경우
--
-- 왜 콜백에서 getState 를 안 부르나
-- ---------------------------------
-- PROBE_ADPCM_BUDGET 0.1.0 이 그것으로 에뮬을 세웠다.  콜백은 카운터만 올리고
-- 프레임 끝에서 한 번만 읽는다.
--
-- ⚠ 화면에 아무것도 안 그린다.  drawString 은 게임 화면을 가려 판정을 막는다.
--
-- 쓰는 법
--   1) 0.5.10 을 파워사이클로 올린다
--   2) 음성 대사가 이어지는 장면을 지난다 (국장실이 특히 좋다)
--   3) 스크립트를 멈추면 아래 경로에 표가 떨어진다
--
--   dump  snatcher_tool/logs/cost_v010.tsv     ★프로브와 같은 판번호

local OUT = "C:/snatcher/snatcher_tool/logs/cost_v010.tsv"

local AC_WRITE  = 0x1A10
local STATE     = 0x7FDF
local ADPCM_ST  = 0x180D
local PLAY_BIT  = 0x20
local BURST     = 512          -- 이보다 많이 몰리면 엔진 복사로 본다

local cpu = emu.memType.cpu

local acw       = 0            -- 이번 프레임 $1A10 쓰기 수
local frame     = 0
local arms      = 0            -- STATE 0 -> 1
local clips     = 0            -- 재생 꺼짐 -> 켜짐
local bursts    = 0            -- 512 회 넘은 프레임
local total_ac  = 0
local last_state = -1
local playing   = false
local rows      = {}
local last_arm_frame = nil

local function say(m) emu.log(m); print(m) end

emu.addMemoryCallback(function()
  acw = acw + 1
end, emu.callbackType.write, AC_WRITE, AC_WRITE, emu.cpuType.pce, cpu)

emu.addMemoryCallback(function(addr, value)
  if value == 1 and last_state ~= 1 then
    arms = arms + 1
    last_arm_frame = frame
  end
  last_state = value
end, emu.callbackType.write, STATE, STATE, emu.cpuType.pce, cpu)

emu.addEventCallback(function()
  frame = frame + 1
  total_ac = total_ac + acw

  local st = emu.read(ADPCM_ST, cpu)
  local now = (st & PLAY_BIT) ~= 0
  if now and not playing then clips = clips + 1 end
  playing = now

  if acw >= BURST then
    bursts = bursts + 1
    rows[#rows + 1] = {
      frame = frame, writes = acw, arms = arms, clips = clips,
      playing = now and 1 or 0, state = last_state,
    }
    if bursts <= 12 then
      say(("  f%-8d $1A10 쓰기 %5d  arm %3d  클립 %3d  state %s")
          :format(frame, acw, arms, clips, tostring(last_state)))
    end
  end
  acw = 0
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  local f = io.open(OUT, "w")
  if f then
    f:write("frame\twrites\tarms\tclips\tplaying\tstate\n")
    for _, r in ipairs(rows) do
      f:write(("%d\t%d\t%d\t%d\t%d\t%s\n")
              :format(r.frame, r.writes, r.arms, r.clips, r.playing,
                      tostring(r.state)))
    end
    f:close()
  end
  say("")
  say(("프레임 %d  ·  $1A10 쓰기 합계 %d"):format(frame, total_ac))
  say(("arm(STATE 0->1) %d  ·  클립(재생 시작) %d  ·  적재 프레임 %d")
      :format(arms, clips, bursts))
  if clips > 0 then
    say(("클립당 arm  %.2f"):format(arms / clips))
    say(("클립당 AC 쓰기  %.0f B"):format(total_ac / clips))
  end
  say("")
  if arms == 0 then
    say("★ arm 이 0 이다.  음성 자막이 나오는 장면을 안 지났거나")
    say("  STATE 주소가 이 판과 다르다 -- 세운 값이 못 답한 것이니 믿지 말 것")
  elseif clips > 0 and arms >= clips then
    say("-> 클립마다(또는 그보다 자주) 671 B 를 나른다.  소유자 예상대로다")
  else
    say("-> 어떤 클립은 적재를 건너뛴다.  resident_still 이 먹은 것")
  end
  say(("dump  %s"):format(OUT))
end, emu.eventType.scriptEnded)

say("PROBE_ARM_TRANSPORT 0.1.0 -- 세기만 한다.  화면에 안 그린다")
say(("  $1A10 쓰기 · STATE $%04X · ADPCM $%04X bit5"):format(STATE, ADPCM_ST))
