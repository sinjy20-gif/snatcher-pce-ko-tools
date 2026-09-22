-- CDDA 0.3.0 -- 0.6.0-rc12-cdda-ac-latch-init 전용
--
-- 순수 관측. 메모리와 화면을 바꾸지 않는다.
-- 완료 표식은 게임 RAM이 아니라 AC $1F1EE7에 있으며 값 $A5만 유효하다.
-- 이 Lua는 표식을 쓰고 지우는 코드 진입점을 관측해 상태를 기록한다.
--
-- Track 20 합격:
--   CLEAR -> ARM 1 -> MARK_DONE 1 -> STOPPED 1 -> SUPPRESS >= 1
--   그 뒤 ARM 추가 0, 다음 장면 ADPCM_ARM >= 1

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local STATE, ADPCM_STATE = 0x5E1A, 0x7FDF

local PC_BOOT_CLEAR    = 0xF3AE
local PC_REQUEST_CLEAR = 0xF879
local PC_START         = 0xF8DE
local PC_SUPPRESS      = 0xF941
local PC_FRESH         = 0xF944
local PC_MARK_DONE     = 0xEEE3
local PC_STOPPED       = 0xEF12
local PC_REQUEST       = 0xFE8F

local stamp = os.date('%Y%m%d_%H%M%S')
local path = 'C:/snatcher/dump/cdda_latch_0_3_0_' .. stamp .. '.tsv'
local out = assert(io.open(path, 'w'))
out:write('frame\tkind\tpc\tcdda_state\tac_latch_model\tarmed_bcd\tsubq_bcd\traw\tp263c\tp2638\tadpcm_state\tnote\n')

local frame, rows, latch = 0, 0, -1
local n = { boot_clear=0, request=0, request_clear=0, start=0, fresh=0,
            suppress=0, mark=0, stopped=0, arm=0, adpcm_arm=0 }

local function rb(a) return emu.read(a, MEM, false) or 0 end
local function say(s) emu.log(s); print(s) end
local function pc()
  local ok, st = pcall(emu.getState)
  if not ok or type(st) ~= 'table' or type(st.cpu) ~= 'table' then return -1 end
  return st.cpu.pc or st.cpu.PC or -1
end
local function row(kind, note)
  local p = pc()
  out:write(string.format('%d\t%s\t%s\t%02X\t%s\t%02X\t%02X\t%02X\t%02X\t%02X\t%02X\t%s\n',
    frame, kind, p >= 0 and string.format('%04X', p) or '-', rb(STATE),
    latch < 0 and '?' or string.format('%02X', latch), rb(0x5E1B), rb(0x20A2),
    rb(0x26F9), rb(0x263C), rb(0x2638), rb(ADPCM_STATE), note or ''))
  rows = rows + 1
  if rows % 16 == 0 then out:flush() end
end
local function onExec(addr, kind, key, effect)
  emu.addMemoryCallback(function()
    if effect == 'clear' then latch = 0 elseif effect == 'mark' then latch = 0xA5 end
    n[key] = n[key] + 1
    row(kind, '')
    if kind == 'BOOT_CLEAR' or kind == 'REQUEST_CLEAR' or kind == 'MARK_DONE'
       or kind == 'SUPPRESS' or kind == 'STOPPED' then
      say(string.format('f%-7d %-13s state=%02X latch=%s raw=%02X', frame, kind,
        rb(STATE), latch < 0 and '?' or string.format('%02X', latch), rb(0x26F9)))
    end
  end, emu.callbackType.exec, addr, addr, CPU, MEM)
end

onExec(PC_BOOT_CLEAR,    'BOOT_CLEAR',    'boot_clear',    'clear')
onExec(PC_REQUEST,       'REQUEST',       'request',       nil)
onExec(PC_REQUEST_CLEAR, 'REQUEST_CLEAR', 'request_clear', 'clear')
onExec(PC_START,         'START',         'start',         nil)
onExec(PC_FRESH,         'FRESH',         'fresh',         nil)
onExec(PC_MARK_DONE,     'MARK_DONE',     'mark',          'mark')
onExec(PC_STOPPED,       'STOPPED',       'stopped',       nil)
onExec(PC_SUPPRESS,      'SUPPRESS',      'suppress',      nil)

emu.addMemoryCallback(function(_addr, value)
  if value == 2 then n.arm = n.arm + 1; row('ARM', 'cdda state=2')
  elseif value == 0 then row('CDDA_STATE0', '')
  else row('CDDA_STATE', string.format('value=%02X', value)) end
end, emu.callbackType.write, STATE, STATE, CPU, MEM)

emu.addMemoryCallback(function(_addr, value)
  if value == 1 then n.adpcm_arm = n.adpcm_arm + 1; row('ADPCM_ARM', '')
  elseif value == 0 then row('ADPCM_STATE0', '') end
end, emu.callbackType.write, ADPCM_STATE, ADPCM_STATE, CPU, MEM)

emu.addEventCallback(function() frame = frame + 1 end, emu.eventType.endFrame)
emu.addEventCallback(function()
  local summary = string.format(
    'frames=%d boot_clear=%d request_clear=%d arm=%d mark=%d stopped=%d suppress=%d adpcm_arm=%d',
    frame, n.boot_clear, n.request_clear, n.arm, n.mark, n.stopped, n.suppress, n.adpcm_arm)
  out:write('#\n# ' .. summary .. '\n'); out:close()
  say(''); say('CDDA 0.3.0 끝  ' .. summary); say('-> ' .. path)
end, emu.eventType.scriptEnded)

say('CDDA 0.3.0 AC 재생 건 완료 표식 관측 시작')
say('시험판: 0.6.0-rc12-cdda-ac-latch-init')
say('-> ' .. path)
