-- SUB 0.5.181 -- 자막이 **마스터 시각에 뜨는가** 를 구간마다 잰다
--
-- ★ 순수 관측.  아무것도 안 쓴다.  화면에도 아무것도 안 그린다.
--
-- 왜 이걸 재나
-- ------------
-- 0.5.5 에서 `elapsed` 를 "스케줄러 호출 횟수" 대신 **VBlank 시계($201B) 차분**
-- 으로 바꿨다.  잘 됐는지는 호출 횟수가 아니라 **자막이 제 시각에 뜨는가** 로
-- 판정해야 한다.
--
-- 렌더러의 `record_ptr`($5B80+327)은 스케줄러가 구간을 심을 때마다 바뀐다.
-- 그러니 그 바뀐 프레임을 잡아 **무장 이후 경과 프레임**을 재고, 색인이 구워둔
-- 기대 프레임과 대면 오차가 바로 나온다.
--
--     오차 0 근처가 계속 유지    ✔ 시계가 맞는다
--     뒤로 갈수록 커진다         ✘ 아직 밀린다 (0.5.4 는 끝에서 200+ 프레임)
--
-- ⚠ 정상 속도로 볼 것.  오버클럭에서는 원래 안 밀리므로 판정이 안 된다.
--
-- 기대값 (build/cutscene_subs/cdda_mini_index_all.tsv 의 트랙 17, 35 구간)
-- 트랙이 17 이 아니면 대조는 건너뛰고 기록만 한다.
--
-- 산출물  C:/snatcher/dump/cue_accuracy_0_5_181_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/cue_accuracy_0_5_181_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('seq\tframe\tsince_arm\tsched\texpect\terr_frames\terr_sec\trecord_ptr\n')

local function say(m) emu.log(m); print(m) end

local SCHED    = 0xECF9
local ENG      = 0x5B80
local RECPTR   = ENG + 327
local TRACKBCD = ENG + 660

local EXPECT = {2165, 2454, 2673, 2827, 3017, 3166, 3330, 3497, 3662, 3920,
                4057, 4298, 4449, 4572, 4671, 4846, 4998, 5183, 5402, 5611,
                5717, 5834, 5991, 6055, 6194, 6377, 6464, 6542, 6674, 6766,
                6920, 7002, 7118, 7234, 7333}

local frame, sched = 0, 0
local bank1 = false
local armed_at = nil
local last_ptr, seq = nil, 0
local worst, worst_at = 0, 0
local track = nil

emu.addMemoryCallback(function() bank1 = true end,
                      emu.callbackType.exec, 0xFFD4, 0xFFD4, CPU, MEM)
emu.addMemoryCallback(function() bank1 = false end,
                      emu.callbackType.exec, 0xF050, 0xF050, CPU, MEM)

emu.addMemoryCallback(function()
  if not bank1 then return end
  sched = sched + 1
  if not armed_at then
    armed_at = frame
    track = emu.read(TRACKBCD, MEM, false) or -1
    say(('★무장  f%d   트랙 BCD $%02X%s'):format(
      frame, track, track == 0x17 and '  (기대값과 대조한다)' or '  (트랙 17 이 아니라 대조는 건너뛴다)'))
  end
end, emu.callbackType.exec, SCHED, SCHED, CPU, MEM)

local function rd(a) return emu.read(a, MEM, false) or 0 end

emu.addEventCallback(function()
  frame = frame + 1
  if not armed_at then return end

  local ptr = rd(RECPTR) + rd(RECPTR + 1) * 256 + rd(RECPTR + 2) * 65536
  if last_ptr == nil then last_ptr = ptr; return end
  if ptr == last_ptr then return end
  last_ptr = ptr
  -- 철거 때의 $000000 / $FFFFFF 는 구간이 아니다
  if ptr == 0 or ptr == 0xFFFFFF then return end

  seq = seq + 1
  local since = frame - armed_at
  local exp = (track == 0x17) and EXPECT[seq] or nil
  local err = exp and (since - exp) or nil
  if err and math.abs(err) > math.abs(worst) then worst, worst_at = err, seq end

  out:write(('%d\t%d\t%d\t%d\t%s\t%s\t%s\t%06X\n'):format(
    seq, frame, since, sched,
    exp and tostring(exp) or '', err and tostring(err) or '',
    err and ('%.2f'):format(err / 60) or '', ptr))
  out:flush()

  if exp then
    say(('  [%2d] f%-7d 경과 %-6d 기대 %-6d 오차 %+5d (%+.2f s)')
      :format(seq, frame, since, exp, err, err / 60))
  else
    say(('  [%2d] f%-7d 경과 %-6d  $%06X'):format(seq, frame, since, ptr))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  say('')
  say('끝')
  local since = armed_at and (frame - armed_at) or 0
  local lines = {
    ('  무장 f%s · 전체 %d 프레임'):format(armed_at and tostring(armed_at) or '없음', frame),
    ('  잡은 구간 %d 개'):format(seq),
    ('  스케줄러 호출 %d · 무장 뒤 프레임 %d  (호출 기준 뒤처짐 %d)')
      :format(sched, since, since - sched),
  }
  if track == 0x17 and seq > 0 then
    lines[#lines + 1] = ('  ★최대 오차 %+d 프레임 (%+.2f s) -- %d 번째 구간')
      :format(worst, worst / 60, worst_at)
    lines[#lines + 1] = ('  판정: %s'):format(
      math.abs(worst) <= 6 and '✔ 시계가 맞는다 (오차 0.1 초 이내)'
      or math.abs(worst) <= 30 and '△ 약간 밀린다 (0.5 초 이내)'
      or '✘ 아직 밀린다')
  end
  out:write('#\n')
  for _, l in ipairs(lines) do say(l); out:write('# ' .. l .. '\n') end
  out:close()
  say('')
  say('  ★"호출 기준 뒤처짐" 이 커도 상관없다 -- 그건 호출 횟수다.')
  say('    중요한 것은 오차(경과 - 기대) 가 끝까지 0 근처인가다.')
  say('  ' .. PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.181-cue-accuracy armed -- 순수 관측 (★0.5.5 에 올릴 것)')
say('  ⚠ 정상 속도로 · 트랙 17 오프닝을 **끝까지** 틀 것 (35 구간)')
say('  ' .. PATH)
