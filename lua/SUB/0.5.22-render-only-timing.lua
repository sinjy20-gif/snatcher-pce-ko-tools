-- SUB 0.5.22 -- 0.5.18 "창=렌더만" 상태에서 실제 SEI 창 폭을 재확인한다.
--
-- 0.5.21은 정식 경로에서 save 78~79줄, restore 154~157줄,
-- renderer run 67줄을 분리했다.  하지만 0.5.18은 JSR을 NOP으로 바꾸므로
-- 0.5.21의 오염 가드와 동시에 쓸 수 없다.  이 판은 0.5.18을 직접 로드한 뒤
-- 같은 창 경계를 재서, "렌더만으로 남았다"는 관찰의 시간폭을 확인한다.
--
-- Power Cycle 뒤 이 파일 하나만 로드한다. 0.5.18의 예정된 $1600 잔상은 무시한다.

dofile('C:/snatcher/lua/SUB/0.5.18-window-render-only.lua')

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local A = {
  win_in = 0x7F49, save = 0x7F6C, restore = 0x7F7D,
  run = 0x7F82, win_out = 0x7F85,
}
local FRAME_LINES = 263
local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/render_only_timing_0_5_22_' .. STAMP .. '.tsv'
local out = io.open(OUT, 'w')
if out then out:write('frame\tkind\tstart\tend\ttotal\trender\n') end

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

local frame, active, reported, shortRendererReports = 0, nil, 0, 0
local function stamp() return { frame = frame, line = scanline() } end
local function elapsed(a, b)
  if not a or not b or a.line < 0 or b.line < 0 then return -1 end
  local d = (b.frame - a.frame) * FRAME_LINES + b.line - a.line
  return d >= 0 and d or d + FRAME_LINES
end

emu.addMemoryCallback(function() active = { in_ = stamp() } end,
  emu.callbackType.exec, A.win_in, A.win_in, CPU, MEM)
emu.addMemoryCallback(function() if active then active.save = stamp() end end,
  emu.callbackType.exec, A.save, A.save, CPU, MEM)
emu.addMemoryCallback(function() if active then active.restore = stamp() end end,
  emu.callbackType.exec, A.restore, A.restore, CPU, MEM)
emu.addMemoryCallback(function() if active then active.run = stamp() end end,
  emu.callbackType.exec, A.run, A.run, CPU, MEM)
emu.addMemoryCallback(function()
  if not active then return end
  local p, stop = active, stamp()
  local kind = p.run and 'renderer' or (p.save and 'start' or (p.restore and 'restore' or 'idle'))
  local total, render = elapsed(p.in_, stop), elapsed(p.run, stop)
  reported = reported + 1
  -- 짧은 매프레임 renderer는 TSV에만 남긴다. 콘솔은 첫 표본 셋과
  -- 실제 원인을 가르는 20줄 이상 버스트만 찍어 로그 폭주를 막는다.
  local show = total >= 20
  if kind == 'renderer' and shortRendererReports < 3 then
    shortRendererReports = shortRendererReports + 1
    show = true
  end
  if show then
    emu.log(string.format('SUB 0.5.22 #%d %s · 창[%d..%d] %d줄 · renderer %d줄',
      reported, kind, p.in_.line, stop.line, total, render))
  end
  if out then
    out:write(string.format('%d\t%s\t%d\t%d\t%d\t%d\n',
      frame, kind, p.in_.line, stop.line, total, render))
    out:flush()
  end
  active = nil
end, emu.callbackType.exec, A.win_out, A.win_out, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  emu.drawString(4, 96, string.format('0.5.22 render-only timing · %d창', reported),
    0x80FF80, 0x000000)
end, emu.eventType.endFrame)

emu.log('SUB 0.5.22-render-only-timing armed -- 0.5.18 패치 상태에서 SEI 창/renderer 폭 측정')
emu.log('  renderer 행의 창 폭과 renderer 폭이 0.5.21의 67줄과 같은지 확인할 것')
emu.log('  TSV: ' .. OUT)
