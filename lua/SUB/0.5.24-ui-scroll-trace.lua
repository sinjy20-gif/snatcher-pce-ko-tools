-- SUB 0.5.24 -- UI 호출 때 생기는 그림 밀림을 재는 독립 VDC 프로브 (쓰기 0 B)
--
-- 자막 엔진을 로드하지 않는다. 게임의 VDC 스크롤/분할 쓰기만 관찰한다.
-- 기록 대상: CR($05), RCR($06), BXR($07), BYR($08), MWR($09), DVSSR($13)
-- 각 쓰기의 프레임, 스캔라인, PC, 완성 중인 16-bit 값을 TSV로 남긴다.
--
-- 사용:
--   1) 다른 Lua를 모두 끄고 이 파일 하나만 로드
--   2) 국장실에서 같은 UI를 3~5회 열고 닫기
--   3) 그림이 밀린 것을 본 즉시 E (선택 사항; 전 프레임을 항상 기록함)
--   4) Stop. 강제 종료해도 매 프레임 flush하므로 마지막까지 대부분 남는다.

local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/ui_scroll_trace_0_5_24_' .. STAMP .. '.tsv'
local out = assert(io.open(OUT, 'w'))
out:write('frame\tkind\tseq\tline\treg\thalf\tbyte\tword\tpc\tcr_count\trcr_count\tbxr_count\tbyr_count\tnote\n')
out:flush()

local REG_NAME = {
  [0x05] = 'CR', [0x06] = 'RCR', [0x07] = 'BXR', [0x08] = 'BYR',
  [0x09] = 'MWR', [0x13] = 'DVSSR',
}

local LINE_KEY
local function machine_state()
  local ok, s = pcall(emu.getState)
  if ok and type(s) == 'table' then return s end
  return {}
end

local function scanline(s)
  if LINE_KEY == nil then
    LINE_KEY = false
    for _, k in ipairs({'vdc.scanline', 'scanline', 'vdc.vCounter', 'ppu.scanline'}) do
      if type(s[k]) == 'number' then LINE_KEY = k; break end
    end
  end
  if LINE_KEY == false then return -1 end
  local v = s[LINE_KEY]
  return type(v) == 'number' and math.floor(v) or -1
end

local function cpu_pc(s)
  for _, k in ipairs({'cpu.pc', 'cpu.programCounter', 'pc', 'cpu.PC'}) do
    if type(s[k]) == 'number' then return math.floor(s[k]) & 0xFFFF end
  end
  return 0
end

local frame, seq, selected = 0, 0, 0
local words = {}
local counts = { [0x05]=0, [0x06]=0, [0x07]=0, [0x08]=0 }
local events = {}
local closed = false

emu.addMemoryCallback(function(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF
  if port == 0 then
    selected = value
    return
  end
  if port ~= 2 and port ~= 3 then return end
  local name = REG_NAME[selected]
  if not name then return end

  local old = words[selected] or 0
  local word
  if port == 2 then
    word = (old & 0xFF00) | value
  else
    word = (old & 0x00FF) | (value << 8)
  end
  words[selected] = word
  if counts[selected] ~= nil then counts[selected] = counts[selected] + 1 end

  seq = seq + 1
  local s = machine_state()
  events[#events + 1] = {
    seq=seq, line=scanline(s), reg=name,
    half=(port == 2) and 'lo' or 'hi', byte=value, word=word, pc=cpu_pc(s),
  }
end, emu.callbackType.write, 0x0000, 0x0003, CPU, MEM)

local lastMark = -1000
local marks = 0

local function write_event(e)
  out:write(string.format('%d\tWRITE\t%d\t%d\t%s\t%s\t%02X\t%04X\t%04X\t\t\t\t\t\n',
    frame, e.seq, e.line, e.reg, e.half, e.byte, e.word, e.pc))
end

emu.addEventCallback(function()
  frame = frame + 1
  local marked = emu.isKeyPressed('E') and (frame - lastMark > 30)
  if marked then
    lastMark = frame
    marks = marks + 1
  end

  for _, e in ipairs(events) do write_event(e) end
  out:write(string.format('%d\tFRAME\t\t\t\t\t\t\t\t%d\t%d\t%d\t%d\t%s\n',
    frame, counts[0x05], counts[0x06], counts[0x07], counts[0x08],
    marked and ('MARK #' .. marks .. ' -- 그림 밀림/버튼 순간') or ''))
  out:flush()

  if marked then
    emu.log(string.format('SUB 0.5.24 MARK #%d at frame %d', marks, frame))
  end
  emu.drawString(4, 64, string.format(
    '0.5.24 UI trace · CR %d RCR %d BXR %d BYR %d · E표식 %d',
    counts[0x05], counts[0x06], counts[0x07], counts[0x08], marks),
    0x80FF80, 0x80000000, 1)

  events = {}
  seq = 0
  counts[0x05], counts[0x06], counts[0x07], counts[0x08] = 0, 0, 0, 0
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if closed then return end
  closed = true
  out:write(string.format('# end\tframes=%d\tmarks=%d\n', frame, marks))
  out:close()
  emu.log('SUB 0.5.24 stopped -- ' .. OUT)
end, emu.eventType.scriptEnded)

emu.log('SUB 0.5.24-ui-scroll-trace loaded -- 독립 읽기 전용 · 게임 쓰기 0 B')
emu.log('  다른 Lua OFF · 같은 UI 3~5회 · 밀림을 본 즉시 E (표식은 선택)')
emu.log('  CR/RCR/BXR/BYR/MWR/DVSSR + scanline + writer PC')
emu.log('  매 프레임 저장: ' .. OUT)
