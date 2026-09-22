-- CDDA 0.2.0 -- 0.6.0-rc10-cdda-once 전용 재생 건 완료 표식 검증
--
-- 순수 관측이다. 메모리와 화면을 바꾸지 않는다.
-- 반드시 이 시험판 BIOS와 함께 쓰고, 상태 변경 Lua는 같이 켜지 않는다.
--
-- 합격 핵심 (Track 20):
--   REQUEST 1회 -> ARM 1회 -> LATCH_SET 1회 -> TEARDOWN 1회
--   그 뒤 음악이 남아 있는 동안 SUPPRESS >= 1, ARM 추가 0회
--   다음 ADPCM에서 ADPCM_ARM이 다시 찍혀야 한다.
--
-- 산출물: C:/snatcher/dump/cdda_latch_0_2_0_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local STATE = 0x5E1A
local TRACK = 0x5E1B
local LATCH = 0x5E1F
local ADPCM_STATE = 0x7FDF

-- 0.6.0-rc10-cdda-once의 생성 JSON에서 고정한 주소.
local PC_REQUEST  = 0xFE8F  -- 실제 CD-DA 요청: 여기서 latch를 먼저 지운다
local PC_START    = 0xF899  -- cdda_start: latch 검사
local PC_SUPPRESS = 0xF89E  -- 소진한 같은 재생 건의 자동 재무장 거부
local PC_FRESH    = 0xF8A1  -- latch=0, 정상 무장 계속
local PC_WAIT     = 0xEEDB  -- 자막 소진/스킵 뒤 철거 판정
local PC_STOPPED  = 0xEEF6  -- 즉시 반납 경로

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH = 'C:/snatcher/dump/cdda_latch_0_2_0_' .. STAMP .. '.tsv'
local out = assert(io.open(PATH, 'w'))
out:write('frame\tkind\tpc\tcdda_state\tlatch\tarmed_bcd\tsubq_bcd\traw\tp263c\tp2638\tadpcm_state\tnote\n')

local frame, rows = 0, 0
local n = { request=0, start=0, fresh=0, wait=0, suppress=0, arm=0,
            teardown=0, latch_set=0, latch_clear=0, adpcm_arm=0 }

local function rb(a) return emu.read(a, MEM, false) or 0 end
local function say(s) emu.log(s); print(s) end
local function pc()
  local ok, st = pcall(emu.getState)
  if not ok or type(st) ~= 'table' or type(st.cpu) ~= 'table' then return -1 end
  return st.cpu.pc or st.cpu.PC or -1
end

local function row(kind, note)
  local p = pc()
  out:write(string.format('%d\t%s\t%s\t%02X\t%02X\t%02X\t%02X\t%02X\t%02X\t%02X\t%02X\t%s\n',
    frame, kind, p >= 0 and string.format('%04X', p) or '-',
    rb(STATE), rb(LATCH), rb(TRACK), rb(0x20A2), rb(0x26F9),
    rb(0x263C), rb(0x2638), rb(ADPCM_STATE), note or ''))
  rows = rows + 1
  if rows % 16 == 0 then out:flush() end
end

local function watchExec(addr, kind, key)
  emu.addMemoryCallback(function()
    n[key] = n[key] + 1
    row(kind, '')
    if kind == 'REQUEST' or kind == 'SUPPRESS' or kind == 'STOPPED' then
      say(string.format('f%-7d %-10s state=%02X latch=%02X track=%02X raw=%02X',
        frame, kind, rb(STATE), rb(LATCH), rb(TRACK), rb(0x26F9)))
    end
  end, emu.callbackType.exec, addr, addr, CPU, MEM)
end

watchExec(PC_REQUEST,  'REQUEST',  'request')
watchExec(PC_START,    'START',    'start')
watchExec(PC_SUPPRESS, 'SUPPRESS', 'suppress')
watchExec(PC_FRESH,    'FRESH',    'fresh')
watchExec(PC_WAIT,     'WAIT',     'wait')
watchExec(PC_STOPPED,  'STOPPED',  'teardown')

emu.addMemoryCallback(function(_addr, value)
  if value == 2 then n.arm = n.arm + 1; row('ARM', 'cdda state=2')
  elseif value == 0 then row('STATE0', 'cdda state=0')
  else row('CDDA_STATE', string.format('value=%02X', value)) end
end, emu.callbackType.write, STATE, STATE, CPU, MEM)

emu.addMemoryCallback(function(_addr, value)
  if value == 0 then n.latch_clear = n.latch_clear + 1; row('LATCH_CLEAR', 'new request')
  else n.latch_set = n.latch_set + 1; row('LATCH_SET', 'subtitle list drained') end
end, emu.callbackType.write, LATCH, LATCH, CPU, MEM)

emu.addMemoryCallback(function(_addr, value)
  if value == 1 then n.adpcm_arm = n.adpcm_arm + 1; row('ADPCM_ARM', '')
  elseif value == 0 then row('ADPCM_STATE0', '') end
end, emu.callbackType.write, ADPCM_STATE, ADPCM_STATE, CPU, MEM)

emu.addEventCallback(function() frame = frame + 1 end, emu.eventType.endFrame)

emu.addEventCallback(function()
  local summary = string.format(
    'frames=%d request=%d arm=%d latch_set=%d teardown=%d suppress=%d adpcm_arm=%d',
    frame, n.request, n.arm, n.latch_set, n.teardown, n.suppress, n.adpcm_arm)
  out:write('#\n# ' .. summary .. '\n')
  out:close()
  say('')
  say('CDDA 0.2.0 끝  ' .. summary)
  say('-> ' .. PATH)
end, emu.eventType.scriptEnded)

say('CDDA 0.2.0 재생 건 완료 표식 관측 시작')
say('시험판: 0.6.0-rc10-cdda-once')
say('-> ' .. PATH)
