-- SUB 0.4.13
--
-- 0.4.12의 no-subtitle A/B를 그대로 수행하면서, $20F5 writer만 별도 로그에
-- 처음부터 끝까지 보존한다.  0.4.11의 공용 lock ring은 반복되는 $20F2 쓰기에
-- 밀려 $20F5 writer가 사라졌으므로 이 파일로 분리한다.
--
-- 사용: E6800_0E보다 앞 세이브에서 이 Lua 하나만 로드하고 008FA4 정지까지 진행.
-- 출력: C:\snatcher\dump\probe_20F5_writer_0413.tsv

local OUT = 'C:/snatcher/dump/probe_20F5_writer_0413.tsv'
local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce
local F5 = 0x20F5

local frame = 0
local writes = 0
local f = io.open(OUT, 'w')

local function byte(addr)
  return emu.read(addr & 0xFFFF, MEM) or 0
end

local function number(s, key)
  local v = s[key]
  return type(v) == 'number' and v or 0
end

local function snapshot(tag, callbackValue)
  if not f then return end
  local ok, s = pcall(emu.getState)
  s = ok and s or {}
  local read = number(s, 'cdrom.adpcm.readAddress')
  local len = number(s, 'cdrom.adpcm.adpcmLength')
  local finish = (read + len) & 0xFFFF
  local value = type(callbackValue) == 'number' and callbackValue or byte(F5)
  f:write(string.format(
    '%d\t%s\t$%04X\t$%02X\t$%02X\t$%02X\t$%02X\t$%02X\t$%02X\t$%02X\t$%02X\t%d\t$%06X\t$%04X\t$%02X\t$%02X\t$%02X\t$%02X\n',
    frame, tag, number(s, 'cpu.pc'), number(s, 'cpu.sp'),
    number(s, 'cpu.a'), number(s, 'cpu.x'), number(s, 'cpu.y'),
    number(s, 'cpu.p'), value & 0xFF, byte(0x20F4), byte(0x20F6),
    s['cdrom.adpcm.playing'] == true and 1 or 0,
    number(s, 'cdrom.scsi.sector'), finish,
    number(s, 'cdrom.adpcm.playbackRate'), byte(0x1802), byte(0x1803),
    byte(0x7FDF)))
  f:flush()
end

if f then
  f:write('# PROBE_20F5_WRITER 0.4.13 -- dedicated, never overwritten by $20F2 noise\n')
  f:write('frame\ttag\tpc\tsp\ta\tx\ty\tp\tvalue\t20F4\t20F6\tadpcm_playing\tsector\tfinish\trate\tirq_mask\tirq_status\tsub_state\n')
  snapshot('SCRIPT_START', byte(F5))
else
  emu.log('SUB 0.4.13: cannot open ' .. OUT)
end

emu.addMemoryCallback(function(address, value)
  writes = writes + 1
  snapshot('WRITE_' .. writes, value)
  emu.log(string.format('SUB 0.4.13 $20F5 WRITE #%d PC/state logged', writes))
end, emu.callbackType.write, F5, F5, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  snapshot('SCRIPT_END', byte(F5))
  if f then f:close(); f = nil end
end, emu.eventType.scriptEnded)

emu.log('SUB 0.4.13 loaded -- dedicated $20F5 writer log + no-subtitle A/B')
emu.log('  output: ' .. OUT)

-- 0.4.12가 자막 시작을 차단하고, 그 안에서 0.4.11 IRQ 프로브도 함께 불러온다.
dofile('C:/snatcher/lua/SUB/0.4.12.lua')
