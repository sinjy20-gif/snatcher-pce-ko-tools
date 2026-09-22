-- PROBE_SUBTITLE_TRAFFIC 0.1.0 -- 자막이 나올 때 복사가 몇 번, 얼마나 일어나나
--
-- 질문 (소유자, 2026-09-05)
-- ------------------------
--   "자막 출력 시점에 복사가 얼마나 자주 몇번 이루어지는지"
--
-- 앞 프로브가 못 본 것
-- --------------------
-- PROBE_ARM_TRANSPORT 는 `$1A10`(AC 쓰기)만 셌다.  그래서 **엔진 적재만** 보였다.
--
--   실측 (0.1.0/0.2.0):  arm 마다 ~720 B · 클립마다 한 번 · 그중 쓸모 6~9 B
--
-- 그런데 자막이 실제로 그려질 때 일어나는 일은 그게 아니다.
--
--   글리프를 AC 에서 **읽어** VRAM 으로 밀어넣는다   -> $1A00 읽기 + VDC 쓰기
--   헬퍼가 자막 VRAM 을 AC 에 저장/복원한다          -> 양쪽 다
--
-- 그 둘을 안 세면 "자막 한 줄에 얼마" 를 말할 수 없다.
--
-- 무엇을 세나 -- 세 창구를 프레임마다
-- -----------------------------------
--   $1A00 읽기    AC 읽기 포트 (자동증가).  글리프·엔진·헬퍼 복원이 여기로 온다
--   $1A10 쓰기    AC 쓰기 포트.  엔진 적재·헬퍼 저장이 여기로 나간다
--   $0002 쓰기    VDC 데이터 포트.  VRAM 에 실제로 찍히는 양
--
-- 프레임마다 셋을 찍으면 "몇 번" 과 "얼마나" 가 같이 나온다.  한 프레임에
-- 몰린 양이 곧 그 프레임이 잃은 시간이다 (포트 바이트 루프 ~16 cyc/B,
-- 블록 전송 6 cyc/B -- tools/measure_arm_cost.py 참고).
--
-- ⚠ 화면에 아무것도 안 그린다.
-- ⚠ 콜백은 카운터만 올린다.  getState 는 안 부른다
--    (PROBE_ADPCM_BUDGET 0.1.0 이 그것으로 에뮬을 세웠다).
--
-- 쓰는 법
--   자막이 이어지는 장면을 지난다.  국장실처럼 짧은 문답이 촘촘한 곳이 좋다.
--
--   dump  snatcher_tool/logs/subtitle_traffic_v010.tsv   ★프로브와 같은 판번호

local OUT = "C:/snatcher/snatcher_tool/logs/subtitle_traffic_v010.tsv"

local AC_READ  = 0x1A00
local AC_WRITE = 0x1A10
local VDC_DATA = 0x0002
local STATE    = 0x7FDF
local QUIET    = 16          -- 이보다 적으면 잡음으로 보고 안 적는다
local ENGINE   = 512         -- 이 이상 몰리면 엔진 적재로 본다

local cpu = emu.memType.cpu

local rd, wr, vd = 0, 0, 0
local frame, arms = 0, 0
local last_state = -1
local rows = {}
local sum_rd, sum_wr, sum_vd = 0, 0, 0
local busy, engine_frames = 0, 0
local last_busy_frame = nil
local gaps = {}

local function say(m) emu.log(m); print(m) end

emu.addMemoryCallback(function() rd = rd + 1 end,
  emu.callbackType.read, AC_READ, AC_READ, emu.cpuType.pce, cpu)
emu.addMemoryCallback(function() wr = wr + 1 end,
  emu.callbackType.write, AC_WRITE, AC_WRITE, emu.cpuType.pce, cpu)
emu.addMemoryCallback(function() vd = vd + 1 end,
  emu.callbackType.write, VDC_DATA, VDC_DATA, emu.cpuType.pce, cpu)
emu.addMemoryCallback(function(addr, value)
  if value == 1 and last_state ~= 1 then arms = arms + 1 end
  last_state = value
end, emu.callbackType.write, STATE, STATE, emu.cpuType.pce, cpu)

emu.addEventCallback(function()
  frame = frame + 1
  sum_rd = sum_rd + rd; sum_wr = sum_wr + wr; sum_vd = sum_vd + vd
  local total = rd + wr
  if total >= QUIET or vd >= 64 then
    busy = busy + 1
    local kind = (total >= ENGINE) and "엔진적재" or "자막그리기"
    if total >= ENGINE then engine_frames = engine_frames + 1 end
    if last_busy_frame then gaps[#gaps + 1] = frame - last_busy_frame end
    last_busy_frame = frame
    rows[#rows + 1] = { f = frame, rd = rd, wr = wr, vd = vd,
                        kind = kind, arms = arms }
    if busy <= 40 then
      say(("  f%-7d %-10s AC읽기 %5d  AC쓰기 %5d  VRAM쓰기 %5d")
          :format(frame, kind, rd, wr, vd))
    end
  end
  rd, wr, vd = 0, 0, 0
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  local f = io.open(OUT, "w")
  if f then
    f:write("frame\tkind\tac_read\tac_write\tvdc_write\tarms\n")
    for _, r in ipairs(rows) do
      f:write(("%d\t%s\t%d\t%d\t%d\t%d\n")
              :format(r.f, r.kind, r.rd, r.wr, r.vd, r.arms))
    end
    f:close()
  end
  say("")
  say(("프레임 %d  ·  바쁜 프레임 %d (%.1f%%)  ·  그중 엔진적재 %d")
      :format(frame, busy, busy / math.max(frame, 1) * 100, engine_frames))
  say(("합계  AC읽기 %d · AC쓰기 %d · VRAM쓰기 %d")
      :format(sum_rd, sum_wr, sum_vd))
  say(("arm %d 회"):format(arms))
  if #gaps > 0 then
    table.sort(gaps)
    say(("바쁜 프레임 사이 간격  중앙값 %d · 최소 %d · 최대 %d 프레임")
        :format(gaps[#gaps // 2 + 1], gaps[1], gaps[#gaps]))
  end
  if busy > 0 then
    say("")
    say("★ 한 프레임에 몰린 양이 그 프레임이 잃은 시간이다")
    say("   포트 바이트 루프 ~16 cyc/B · 블록 전송 6 cyc/B · 1 스캔라인 455 cyc")
  end
  say(("dump  %s"):format(OUT))
end, emu.eventType.scriptEnded)

say("PROBE_SUBTITLE_TRAFFIC 0.1.0 -- AC 읽기/쓰기 + VRAM 쓰기를 프레임마다")
say("  화면에 안 그린다.  콜백은 세기만 한다")
