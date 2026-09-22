-- SUB 0.5.21 -- 상주부 SEI 창을 호출 단위로 분해한다 (읽기 전용 프로브)
--
-- 0.5.20 결론: PLP 직후 pending raster IRQ가 BIOS set_RCR($E42B)로 떨어진다.
-- 다음 질문은 창을 실제로 채우는 호출이 무엇인가다. 0.4.6.17의 resident는
-- $7F49-$7FDF, 151 B 고정이며 native_poll_0_8_3/4의 주소를 사용한다.
--
-- Power Cycle 뒤 이 파일 하나만 로드한다. 디스크는 0.4.6.17-reviewed.

assert(rawget(_G, 'SUB_FRAGMENT_FORCE_KEY') == nil and
       rawget(_G, 'SUB_FRAGMENT_FORCE_BASE') == nil,
       '재무장 엔진에서는 SUB_FRAGMENT_FORCE_KEY/BASE 를 쓸 수 없다')

dofile('C:/snatcher/lua/SUB/0.4.89-vdc-rearm.lua')

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local NOP = 0xEA

-- Controller instruction boundaries.  These are source-derived, not guessed:
-- tools/build_subtitle_resident_native_poll_0_8_3.py, ORIGIN=$7F49.
local A = {
  win_in       = 0x7F49, -- PHP
  fec4_call    = 0x7F4F, -- JSR $FEC4
  fec4_return  = 0x7F52,
  select_call  = 0x7F58, -- JSR select_helper
  select_return_copy_call = 0x7F5B, -- select return / JSR copy_helper
  copy_helper_return = 0x7F5E,
  save_call    = 0x7F6C, -- JSR $5B83 (helper save)
  save_return_renderer_call = 0x7F6F, -- save return / JSR copy_renderer
  copy_renderer_return = 0x7F72,
  restore_call = 0x7F7D, -- JSR $5B83 (helper restore)
  restore_return = 0x7F80,
  run_call     = 0x7F82, -- JSR $5B83 (renderer run)
  win_out      = 0x7F85, -- PLP
}

local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/resident_phase_timing_0_5_21_' .. STAMP .. '.tsv'
local out = io.open(OUT, 'w')
if out then
  out:write('frame\tstart\tend\ttotal\tfec4\tselect\tcopy_helper\tsave\tcopy_renderer\trestore\trun\n')
end

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

-- Cross-frame calls are rare here but must not turn into a negative duration.
-- The PC Engine frame has 263 VDC scanlines in this mode.
local FRAME_LINES = 263
local frame = 0
local function stamp() return { frame = frame, line = scanline() } end
local function elapsed(a, b)
  if not a or not b or a.line < 0 or b.line < 0 then return -1 end
  local d = (b.frame - a.frame) * FRAME_LINES + b.line - a.line
  return d >= 0 and d or d + FRAME_LINES
end

-- Cross-experiment RAM contamination guard.
local dirty = false
local function checkForeign()
  if dirty then return end
  for _, f in ipairs({
    { at = 0x7F4A, name = '0.5.16 SEI off' },
    { at = 0x7F5B, name = '0.5.17/18 helper copy offload' },
    { at = 0x7F6F, name = '0.5.17/18 renderer copy offload' },
  }) do
    if (emu.read(f.at, MEM) or -1) == NOP then
      dirty = true
      emu.log(string.format('SUB 0.5.21 ★★ 오염 감지 -- $%04X NOP (%s)', f.at, f.name))
      emu.log('   Power Cycle 후 이 파일 하나만 로드할 것. 현재 판정은 무효다')
      return
    end
  end
end

local active, reported = nil, 0
local function mark(name)
  if active then active[name] = stamp() end
end

local function finish()
  if not active then return end
  active.out = stamp()
  local p = active
  local d = {
    total = elapsed(p.in_, p.out),
    fec4 = elapsed(p.fec4_in, p.fec4_out),
    select = elapsed(p.select_in, p.select_out),
    copy_helper = elapsed(p.copy_helper_in, p.copy_helper_out),
    save = elapsed(p.save_in, p.save_out),
    copy_renderer = elapsed(p.copy_renderer_in, p.copy_renderer_out),
    restore = elapsed(p.restore_in, p.restore_out),
    run = elapsed(p.run_in, p.out),
  }
  local start, stop = p.in_.line, p.out.line
  reported = reported + 1
  emu.log(string.format(
    'SUB 0.5.21 #%d 창[%d..%d] %d줄 · FEC4 %d · sel %d · Hcopy %d · save %d · Rcopy %d · restore %d · run %d',
    reported, start, stop, d.total, d.fec4, d.select, d.copy_helper,
    d.save, d.copy_renderer, d.restore, d.run))
  if out then
    out:write(string.format('%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n',
      frame, start, stop, d.total, d.fec4, d.select, d.copy_helper,
      d.save, d.copy_renderer, d.restore, d.run))
    out:flush()
  end
  active = nil
end

emu.addMemoryCallback(function()
  active = { in_ = stamp() }
end, emu.callbackType.exec, A.win_in, A.win_in, CPU, MEM)
emu.addMemoryCallback(function() mark('fec4_in') end,
  emu.callbackType.exec, A.fec4_call, A.fec4_call, CPU, MEM)
emu.addMemoryCallback(function() mark('fec4_out') end,
  emu.callbackType.exec, A.fec4_return, A.fec4_return, CPU, MEM)
emu.addMemoryCallback(function() mark('select_in') end,
  emu.callbackType.exec, A.select_call, A.select_call, CPU, MEM)
emu.addMemoryCallback(function()
  mark('select_out'); mark('copy_helper_in')
end, emu.callbackType.exec, A.select_return_copy_call, A.select_return_copy_call, CPU, MEM)
emu.addMemoryCallback(function() mark('copy_helper_out') end,
  emu.callbackType.exec, A.copy_helper_return, A.copy_helper_return, CPU, MEM)
emu.addMemoryCallback(function() mark('save_in') end,
  emu.callbackType.exec, A.save_call, A.save_call, CPU, MEM)
emu.addMemoryCallback(function()
  mark('save_out'); mark('copy_renderer_in')
end, emu.callbackType.exec, A.save_return_renderer_call, A.save_return_renderer_call, CPU, MEM)
emu.addMemoryCallback(function() mark('copy_renderer_out') end,
  emu.callbackType.exec, A.copy_renderer_return, A.copy_renderer_return, CPU, MEM)
emu.addMemoryCallback(function() mark('restore_in') end,
  emu.callbackType.exec, A.restore_call, A.restore_call, CPU, MEM)
emu.addMemoryCallback(function() mark('restore_out') end,
  emu.callbackType.exec, A.restore_return, A.restore_return, CPU, MEM)
emu.addMemoryCallback(function() mark('run_in') end,
  emu.callbackType.exec, A.run_call, A.run_call, CPU, MEM)
emu.addMemoryCallback(finish, emu.callbackType.exec, A.win_out, A.win_out, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  checkForeign()
  emu.drawString(4, 84, string.format('0.5.21 phase timing · %d창%s', reported,
    dirty and ' · ★오염 판정무효' or ''),
    dirty and 0x4040FF or 0x80FF80, 0x000000)
end, emu.eventType.endFrame)

emu.log('SUB 0.5.21-resident-phase-timing armed -- SEI 창을 FEC4/select/copy/helper/renderer로 분해')
emu.log('  ★ 창[총] · FEC4 · sel · Hcopy · save · Rcopy · restore · run (모두 스캔라인)')
emu.log('  Power Cycle 후 이 파일 하나만. $7F4A/$7F5B/$7F6F NOP이면 오염 무효.')
emu.log('  TSV: ' .. OUT)
