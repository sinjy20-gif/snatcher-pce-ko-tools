-- SUB 0.5.179 -- 마지막 자막이 왜 안 뜨나: 철거 시점을 프레임 단위로 본다
--
-- ★ 순수 관측.  아무것도 안 쓴다.  화면에도 아무것도 안 그린다.
--
-- 어디까지 왔나
-- -------------
-- 0.5.3 에서 스케줄러의 오프바이원을 고쳤다 (`part+1 < count` -> `part < count`).
-- 그런데 **트랙 17 의 마지막 줄은 여전히 안 뜬다** (실기 · 오버클럭 양쪽).
--
-- 소스를 보니 항목이 소진되면 이렇게 된다:
--
--     cdda_finished:
--         LDA ready
--         BEQ  cdda_state3      ; ready==0 -> 정리
--         STZ  ready            ; 아니면 이번 프레임은 state 유지
--         BRA  cdda_store
--     cdda_state3:
--         LDA #$03 / STA STATE  ; 렌더러 철거
--
-- 즉 **1~2 프레임 안에 철거**한다.  마지막 항목은 소비되자마자 이 경로를 타므로
-- 91 프레임(1.5 초) 떠 있어야 할 것이 사실상 0 프레임이 된다.
--
-- 다만 철거가 몇 프레임 만에 오는지는 `ready` 의 거동에 달려 있다:
--     렌더러가 표시 중 매 프레임 ready=1 로 유지하면  -> STZ 와 밀당하며 버틴다
--     한 번만 1 로 올리고 만다면                      -> 두 프레임 만에 철거
-- 이건 추측하면 안 된다.  그래서 잰다.
--
-- 무엇을 남기나
-- -------------
-- 스케줄러 호출이 END_FROM 을 넘으면 **매 프레임** 남긴다 (트랙 17 의 마지막
-- 구간은 start_frame 7333 이다).  그 표에서 이렇게 읽는다:
--
--     record_ptr 가 마지막으로 바뀐 프레임      = 마지막 항목이 심긴 순간
--     그 뒤 ready 가 어떻게 움직이나            = 렌더러가 표시를 유지하는가
--     STATE 가 3 이 된 프레임                   = 철거 시점
--     (심긴 순간 ~ 철거) 프레임 수              ★이게 91 이어야 정상이다
--
-- 산출물  C:/snatcher/dump/teardown_0_5_179_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/teardown_0_5_179_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tsched\tstate\tready\tcount\trecptr_lo\trecptr_mid\trecptr_hi\tsubq_trk\tnote\n')

local function say(m) emu.log(m); print(m) end

local SCHED = 0xECF9
local STATE = 0x7FDF
local ENG   = 0x5B80
local READY, RECPTR, COUNT = ENG + 326, ENG + 327, ENG + 330
local SUBQ_TRK = 0x20A2

-- 트랙 17 마지막 구간의 start_frame.  그 조금 전부터 매 프레임 남긴다.
local END_FROM = 7200

local frame, sched = 0, 0
local bank1 = false
local armed_at = nil
local logging = false
local last_ptr, ptr_changed_at, ptr_changes = nil, nil, 0
local state3_at = nil
local rows = 0

emu.addMemoryCallback(function() bank1 = true end,
                      emu.callbackType.exec, 0xFFD4, 0xFFD4, CPU, MEM)
emu.addMemoryCallback(function() bank1 = false end,
                      emu.callbackType.exec, 0xF050, 0xF050, CPU, MEM)

emu.addMemoryCallback(function()
  if not bank1 then return end
  sched = sched + 1
  if not armed_at then
    armed_at = frame
    say(('★스케줄러 첫 호출  f%d  (sched %d 부터 매 프레임 기록)'):format(frame, END_FROM))
  end
  if not logging and sched >= END_FROM then
    logging = true
    say(('★기록 시작  f%d  sched=%d'):format(frame, sched))
  end
end, emu.callbackType.exec, SCHED, SCHED, CPU, MEM)

local function rd(a) return emu.read(a, MEM, false) or -1 end

emu.addEventCallback(function()
  frame = frame + 1
  if not logging then return end

  local st, ready = rd(STATE), rd(READY)
  local p0, p1, p2 = rd(RECPTR), rd(RECPTR + 1), rd(RECPTR + 2)
  local ptr = p0 + p1 * 256 + p2 * 65536
  local note = ''

  if last_ptr and ptr ~= last_ptr then
    ptr_changes = ptr_changes + 1
    ptr_changed_at = frame
    note = 'RECPTR_CHANGED'
    say(('  record_ptr 바뀜  f%-7d sched=%-6d $%06X  ready=%02X'):format(frame, sched, ptr, ready))
  end
  last_ptr = ptr

  if st == 0x03 and not state3_at then
    state3_at = frame
    note = (note ~= '' and note .. '+' or '') .. 'STATE3'
    say(('★STATE=3 (철거)  f%-7d sched=%-6d  ready=%02X'):format(frame, sched, ready))
    if ptr_changed_at then
      say(('   마지막 항목이 심긴 뒤 %d 프레임 만에 철거됐다 (91 이어야 정상)')
        :format(frame - ptr_changed_at))
    end
  end

  out:write(('%d\t%d\t%02X\t%02X\t%02X\t%02X\t%02X\t%02X\t%02X\t%s\n')
    :format(frame, sched, st, ready, rd(COUNT), p0, p1, p2, rd(SUBQ_TRK), note))
  rows = rows + 1
  if rows % 60 == 0 then out:flush() end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  say('')
  say('끝')
  local lines = {
    ('  전체 프레임              %d'):format(frame),
    ('  스케줄러 호출            %d'):format(sched),
    ('  기록한 줄                %d'):format(rows),
    ('  record_ptr 바뀐 횟수     %d'):format(ptr_changes),
    ('  마지막으로 바뀐 프레임   %s'):format(ptr_changed_at and tostring(ptr_changed_at) or '(없음)'),
    ('  STATE=3 프레임           %s'):format(state3_at and tostring(state3_at) or '(안 왔다)'),
  }
  if ptr_changed_at and state3_at then
    lines[#lines + 1] = ('  ★마지막 항목 표시 길이  %d 프레임 (91 이어야 정상)')
      :format(state3_at - ptr_changed_at)
  end
  out:write('#\n')
  for _, l in ipairs(lines) do say(l); out:write('# ' .. l .. '\n') end
  out:close()
  say('  ' .. PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.179-last-record-teardown armed -- 순수 관측 (★0.5.3 에 올릴 것)')
say('  오프닝 CD-DA 를 **끝까지** 틀 것 (마지막 자막 구간까지 가야 한다)')
say('  ' .. PATH)
