-- SUB 0.5.23 -- 0.5.18 render-only 창과 BIOS RCR=135 writer를 같은 프레임에 묶는다.
--
-- 0.5.20: PLP 뒤 pending IRQ가 즉시 BIOS set_RCR로 간다.
-- 0.5.22: render-only에도 4~13줄 평상시와 49~289줄 버스트가 있다.
-- 이 판은 "renderer [in..out] -> RCR 화면135 write @line"을 한 행으로 남긴다.
-- Power Cycle 뒤 이 파일 하나만 로드한다.

dofile('C:/snatcher/lua/SUB/0.5.18-window-render-only.lua')

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local WIN_IN, RUN, WIN_OUT = 0x7F49, 0x7F82, 0x7F85
local FRAME_LINES = 263
local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/render_rcr_correlation_0_5_23_' .. STAMP .. '.tsv'
local out = io.open(OUT, 'w')
if out then out:write('frame\trender_in\trender_out\trender_lines\trcr135_line\tgap\n') end

local LINE_KEY
local function scanline()
  local ok, s = pcall(emu.getState)
  if not ok or type(s) ~= 'table' then return -1 end
  if LINE_KEY == nil then
    LINE_KEY = false
    for _, k in ipairs({ 'vdc.scanline', 'scanline', 'vdc.vCounter' }) do
      if type(s[k]) == 'number' then LINE_KEY = k; break end
    end
  end
  local v = LINE_KEY and s[LINE_KEY]
  return type(v) == 'number' and math.floor(v) or -1
end

local frame, active, pending, pairs, shortPairs = 0, nil, nil, 0, 0
local function stamp() return { frame = frame, line = scanline() } end
local function elapsed(a, b)
  if not a or not b or a.line < 0 or b.line < 0 then return -1 end
  local d = (b.frame - a.frame) * FRAME_LINES + b.line - a.line
  return d >= 0 and d or d + FRAME_LINES
end

-- Window measurement.  Only run-path invocations can be renderer work.
emu.addMemoryCallback(function() active = { in_ = stamp() } end,
  emu.callbackType.exec, WIN_IN, WIN_IN, CPU, MEM)
emu.addMemoryCallback(function() if active then active.run = stamp() end end,
  emu.callbackType.exec, RUN, RUN, CPU, MEM)
emu.addMemoryCallback(function()
  if not active then return end
  local stop = stamp()
  if active.run then
    pending = { in_ = active.run, out = stop, render = elapsed(active.run, stop) }
  end
  active = nil
end, emu.callbackType.exec, WIN_OUT, WIN_OUT, CPU, MEM)

-- BIOS set_RCR writes VDC reg $06 through $0002/$0003.  The high byte commits
-- the complete value; RCR-64 is the screen-line notation used by 0.5.19/20.
local selected, rcr = 0, 0
emu.addMemoryCallback(function(address, value)
  local port, v = address & 3, (value or 0) & 0xFF
  if port == 0 then selected = v; return end
  if selected ~= 0x06 then return end
  if port == 2 then
    rcr = (rcr & 0xFF00) | v
  elseif port == 3 then
    rcr = (rcr & 0x00FF) | (v << 8)
    if (rcr & 0x03FF) - 64 ~= 135 or not pending then return end
    local write = stamp()
    local gap = elapsed(pending.out, write)
    pairs = pairs + 1
    local show = pending.render >= 20
    if shortPairs < 3 then shortPairs = shortPairs + 1; show = true end
    if show then
      emu.log(string.format(
        'SUB 0.5.23 #%d renderer[%d..%d] %d줄 -> RCR=135 @줄%d (PLP뒤 %d줄)',
        pairs, pending.in_.line, pending.out.line, pending.render, write.line, gap))
    end
    if out then
      out:write(string.format('%d\t%d\t%d\t%d\t%d\t%d\n', frame,
        pending.in_.line, pending.out.line, pending.render, write.line, gap))
      out:flush()
    end
    pending = nil
  end
end, emu.callbackType.write, 0x0000, 0x0003, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  emu.drawString(4, 108, string.format('0.5.23 renderer→RCR135 상관 %d쌍', pairs),
    pairs > 0 and 0x80FF80 or 0x4040FF, 0x000000)
end, emu.eventType.endFrame)

emu.log('SUB 0.5.23-render-rcr-correlation armed -- render-only PLP와 RCR=135 writer를 한 행으로 결합')
emu.log('  기대: renderer 종료 뒤 RCR=135가 곧바로 쓰이며, 긴 버스트일수록 write line도 늦다')
emu.log('  TSV: ' .. OUT)
