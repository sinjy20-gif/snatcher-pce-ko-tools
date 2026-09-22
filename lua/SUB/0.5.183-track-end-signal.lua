-- SUB 0.5.183 -- 트랙이 끝날 때 **무엇이 움직이나** 를 찾는다
--
-- ★ 순수 관측.  아무것도 안 쓴다.  화면에도 아무것도 안 그린다.
--
-- 왜
-- --
-- 0.5.4 에서 "항목 소진 시 즉시 철거" 를 빼고 "트랙이 끝나면 철거" 로 미뤘다.
-- 마지막 자막이 1 프레임만 뜨던 것은 고쳐졌는데, 이번엔 **음성이 끝나도 마지막
-- 자막이 안 사라진다** (소유자 2026-09-05).
--
-- 이유는 둘 중 하나다:
--     ① 스케줄러가 트랙 종료 뒤에도 불리는데 `$20A2` 가 안 바뀌어 정지를 못 잡는다
--        (0.5.178 에서 SUBQ 가 재생 내내 얼어 있는 것을 이미 쟀다)
--     ② 스케줄러가 아예 안 불린다 (그러면 어떤 판정을 넣어도 소용없다)
--
-- 그리고 CD-DA 렌더러는 `timed=False` 로 구워져 레코드의 `frames` 를 **안 센다.**
-- 자막은 "다음 것이 오거나 ready 에 bit7 이 설 때까지" 떠 있다.  그러니 끝을
-- 알려면 트랙 종료 신호가 반드시 필요하다.
--
-- 무엇을 보나 -- 후보를 한꺼번에 늘어놓는다
-- ------------------------------------------
--     sched        스케줄러가 계속 불리나            ★①/② 를 가른다
--     $20A2        SUBQ 트랙 BCD (지금 쓰는 신호)
--     $20A0        SUBQ 상태 (02 = 재생 중)
--     $26F9        cdda_check 의 raw 키
--     $263C/$2638  시작 펄스
--     $222D        게임의 스킵 입력 (참고)
--     STATE $7FDF · ready · record_ptr
--
-- 마지막 구간(트랙 17 = sched 7333)을 지나면 **매 프레임** 남긴다.
-- 값이 바뀐 자리는 콘솔에도 바로 찍는다 -- 그게 쓸 수 있는 종료 신호다.
--
-- ⚠ 오프닝을 **끝까지, 그리고 다음 장면으로 넘어간 뒤 10 초쯤 더** 둘 것.
--    (종료 신호가 장면 전환 뒤에 올 수도 있다)
--
-- 산출물  C:/snatcher/dump/track_end_0_5_183_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/track_end_0_5_183_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))

local function say(m) emu.log(m); print(m) end

local SCHED = 0xECF9
local ENG   = 0x5B80

local WATCH = {
  { name = 'subq_stat', addr = 0x20A0 },
  { name = 'subq_trk',  addr = 0x20A2 },
  { name = 'raw_26F9',  addr = 0x26F9 },
  { name = 'pulse_263C', addr = 0x263C },
  { name = 'pulse_2638', addr = 0x2638 },
  { name = 'skip_222D', addr = 0x222D },
  { name = 'STATE',     addr = 0x7FDF },
  { name = 'ready',     addr = ENG + 326 },
  { name = 'trackbcd',  addr = ENG + 660 },
}

local hdr = { 'frame', 'sched' }
for _, w in ipairs(WATCH) do hdr[#hdr + 1] = w.name end
hdr[#hdr + 1] = 'note'
out:write(table.concat(hdr, '\t') .. '\n')

local FROM = 7300          -- 트랙 17 마지막 구간은 7333 이다
local TAIL = 1800          -- 그 뒤 30 초쯤 본다

local frame, sched = 0, 0
local bank1 = false
local armed_at, log_from = nil, nil
local last = {}
local sched_frozen_at = nil
local last_sched, last_sched_frame = 0, 0

emu.addMemoryCallback(function() bank1 = true end,
                      emu.callbackType.exec, 0xFFD4, 0xFFD4, CPU, MEM)
emu.addMemoryCallback(function() bank1 = false end,
                      emu.callbackType.exec, 0xF050, 0xF050, CPU, MEM)

emu.addMemoryCallback(function()
  if not bank1 then return end
  sched = sched + 1
  if not armed_at then
    armed_at = frame
    say(('★무장 f%d  (sched %d 부터 매 프레임 기록)'):format(frame, FROM))
  end
  if not log_from and sched >= FROM then
    log_from = frame
    say(('★기록 시작 f%d  sched=%d'):format(frame, sched))
  end
end, emu.callbackType.exec, SCHED, SCHED, CPU, MEM)

local function rd(a) return emu.read(a, MEM, false) or -1 end

emu.addEventCallback(function()
  frame = frame + 1
  if not log_from then return end
  if frame > log_from + TAIL then return end

  local note = {}
  local vals = {}
  for _, w in ipairs(WATCH) do
    local v = rd(w.addr)
    vals[#vals + 1] = ('%02X'):format(v)
    if last[w.name] ~= nil and last[w.name] ~= v then
      note[#note + 1] = ('%s %02X->%02X'):format(w.name, last[w.name], v)
      say(('  f%-7d sched=%-6d ★%s $%04X  %02X -> %02X')
        :format(frame, sched, w.name, w.addr, last[w.name], v))
    end
    last[w.name] = v
  end

  -- 스케줄러가 멈췄나
  if sched ~= last_sched then
    last_sched, last_sched_frame = sched, frame
    sched_frozen_at = nil
  elseif not sched_frozen_at and frame - last_sched_frame > 120 then
    sched_frozen_at = last_sched_frame
    note[#note + 1] = 'SCHED_STOPPED'
    say(('  ★스케줄러가 f%d 이후 안 불린다 (sched=%d 에서 멈춤)')
      :format(last_sched_frame, sched))
  end

  out:write(('%d\t%d\t%s\t%s\n')
    :format(frame, sched, table.concat(vals, '\t'), table.concat(note, ' ')))
  if frame % 60 == 0 then out:flush() end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  say('')
  say('끝')
  local lines = {
    ('  무장 f%s · 전체 %d 프레임 · 스케줄러 %d 회')
      :format(armed_at and tostring(armed_at) or '없음', frame, sched),
    ('  기록 시작 f%s'):format(log_from and tostring(log_from) or '(도달 못함)'),
    ('  스케줄러 멈춘 프레임 %s')
      :format(sched_frozen_at and tostring(sched_frozen_at) or '(계속 불렸다)'),
  }
  out:write('#\n')
  for _, l in ipairs(lines) do say(l); out:write('# ' .. l .. '\n') end
  out:close()
  say('')
  say('  읽는 법')
  say('    스케줄러가 계속 불린다 + 바뀐 자리가 있다  -> 그 자리를 종료 신호로 쓴다')
  say('    스케줄러가 멈춘다                          -> 스케줄러로는 못 지운다.')
  say('                                                  렌더러 쪽에서 끝내야 한다')
  say('  ' .. PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.183-track-end-signal armed -- 순수 관측 (★0.5.5 에 올릴 것)')
say('  ⚠ 오프닝을 끝까지 + 다음 장면 넘어간 뒤 10 초쯤 더 둘 것')
say('  ' .. PATH)
