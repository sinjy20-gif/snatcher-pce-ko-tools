-- BG_SHIFT 0.1.0 -- first separation: VRAM content vs display control.
-- Target: 0.7.21, outside abandoned factory. Read-only, no overlays/input.
-- Run this script alone. Idle 3 s, press R before each test group, move menu.
-- All addresses in touched/changes are VRAM WORD addresses (byte = word*2).
-- BAT references include offscreen/UI cells: they are NOT a visible-BG mask.
-- End-frame differences cannot exclude a write-and-restore within one frame.
-- DMA and audit mismatches prevent a negative conclusion from callback counts.

local VERSION = '0.1.0'
local MAX_FRAMES, AUDIT_EVERY, REG_CAP = 3600, 60, 1024
local MEM, VRAM, CPU = emu.memType.pceMemory, emu.memType.pceVideoRam, emu.cpuType.pce
assert(MEM and VRAM and CPU, 'PCE memory/CPU API missing')
local readWord = emu.read16 or emu.readWord
assert(type(readWord) == 'function', 'read16/readWord API missing')
local prefix = 'C:/snatcher/dump/bg_shift_0_1_0_' .. os.date('%Y%m%d_%H%M%S')
local base = prefix
local suffix = 0
while true do
  local f = io.open(base .. '_meta.txt', 'rb')
  if not f then break end
  f:close(); suffix = suffix + 1; base = prefix .. '_' .. suffix
end
local files = {}
local function open(name, header)
  local f = assert(io.open(base .. '_' .. name, 'w'))
  files[#files + 1] = f
  if header then f:write(header .. '\n'); f:flush() end
  return f
end
local meta = open('meta.txt', 'BG_SHIFT ' .. VERSION .. ' -- observations only; no automatic cause verdict')
local frames = open('frames.tsv', 'frame\tguest_frame\tmark\tac_read\tac_write\tvwr_bytes\tvram_callback_bytes\ttouched_words\tchanged_words\tbat_changed\tbat_ref_pattern_changed\tdma_starts\tunknown_select\treg_dropped\taudit\taudit_untracked_changes\tcols\trows\tend_bxr\tend_byr')
local regs = open('registers.tsv', 'frame\tseq\tline\thclock\tpc\treg\tname\thalf\tbyte\tpre_bxr\tpre_byr\tpre_latch_x\tpre_latch_y\tpre_mawr')
local vram = open('vram.tsv', 'frame\tseq\tline\thclock\tpc\tmawr_word\tdata_byte\tphase\tzone_hint')
local changes = open('changes.tsv', 'frame\tword_hex\told_hex\tnew_hex\tin_prev_bat\treferenced_by_prev_bat\tsource')
local touches = open('touched.tsv', 'frame\tfirst_word_hex\tlast_word_hex')
local NAMES = {[0]='MAWR',[1]='MARR',[2]='VWR',[5]='CR',[6]='RCR',[7]='BXR',[8]='BYR',[9]='MWR',[10]='HSR',[11]='HDR',[12]='VPR',[13]='VDW',[14]='VCR',[15]='DCR',[16]='SOUR',[17]='DESR',[18]='LENR',[19]='DVSSR'}
local active, closed, frame, marks, held = false, false, 0, 0, false
local shadow, refs = {}, {}
local cols, rows, batWords = -1, -1, 0
local selected = nil
local mawr = -1
local count, dirty, trace = {}, {}, {}
local totalAuditMissing, totalDrops, totalDma, totalUnknown, totalWrites = 0, 0, 0, 0, 0
local KEY = nil
for _, name in ipairs({'R', 'r', 'KeyR'}) do
  local ok, value = pcall(emu.isKeyPressed, name)
  if ok and type(value) == 'boolean' then KEY = name; break end
end
local function resetCounts()
  count = {acR=0,acW=0,vwr=0,physical=0,dma=0,unknown=0,dropped=0}
  dirty, trace = {}, {}
end
resetCounts()
local function val(s,k) return type(s[k]) == 'number' and s[k] or -1 end
local function say(s) emu.log('BG_SHIFT: ' .. s) end
local function dumpState(s, tag)
  meta:write('\n[' .. tag .. ']\n')
  local keys = {}
  for k,v in pairs(s) do
    if type(v) ~= 'table' then keys[#keys+1] = k end
  end
  table.sort(keys)
  for _,k in ipairs(keys) do meta:write(k .. '=' .. tostring(s[k]) .. '\n') end
  meta:flush()
end
local function writeSnapshot(name)
  local f = assert(io.open(base .. '_' .. name .. '.bin', 'wb'))
  local chunk = {}
  for w=0,0x7FFF do
    local n = shadow[w]
    chunk[#chunk+1] = string.char(n & 255, (n >> 8) & 255)
    if #chunk == 1024 then f:write(table.concat(chunk)); chunk = {} end
  end
  if #chunk > 0 then f:write(table.concat(chunk)) end
  f:close()
end
local function refreshRefs(s)
  cols, rows = val(s,'vdc.hvReg.columnCount'), val(s,'vdc.hvReg.rowCount')
  refs = {}
  if (cols ~= 32 and cols ~= 64 and cols ~= 128) or (rows ~= 32 and rows ~= 64) then
    batWords = 0; return
  end
  batWords = cols * rows
  for w=0,batWords-1 do refs[shadow[w] & 0x7FF] = true end
end
local function finish(reason)
  if closed then return end
  active = false
  meta:write(('\nfinish=%s\nframes=%d\nmarks=%d\naudit_untracked_changes=%d\nreg_dropped=%d\ndma_starts=%d\nunknown_select=%d\nvram_callback_bytes=%d\n'):format(
    reason,frame,marks,totalAuditMissing,totalDrops,totalDma,totalUnknown,totalWrites))
  meta:write('End-frame changes are net changes, not all transient changes.\n')
  meta:write('No callback hit is not proof of no access. Verify VWR/callback coverage and DMA.\n')
  meta:write('BAT refs include UI/offscreen tiles. Identify picture cells before claiming BG damage.\n')
  meta:write('ROM info is metadata, not proof of the BIOS actually loaded. Record selected BIOS separately.\n')
  for _,f in ipairs(files) do f:flush(); f:close() end
  closed = true
  say('saved: ' .. base .. '_meta.txt (' .. reason .. ')')
end
local function observePort(address, value)
  if not active then return end
  local port = address & 3
  value = (value or 0) & 255
  if port == 0 then selected = value & 31; return end
  if port ~= 2 and port ~= 3 then return end
  if selected == nil then count.unknown = count.unknown + 1; return end
  if selected == 0 then
    if port == 2 then mawr = (mawr & 0xFF00) | value
    else mawr = (mawr & 0x00FF) | (value << 8) end
  elseif selected == 2 then
    count.vwr = count.vwr + 1
    -- A VDC word is completed on the high-byte port. Log its destination once
    -- per word; the low byte is still counted in vwr_bytes.
    if port == 3 then
      local s = emu.getState()
      local pc = val(s,'cpu.pc')
      local line, hclock = val(s,'vdc.scanline'), val(s,'vdc.hclock')
      local zone = (mawr >= 0 and mawr < batWords) and 'BAT'
        or (mawr >= 0 and mawr >= 0x1000 and mawr < 0x2000) and 'tile_0x1000_1fff'
        or (mawr >= 0 and mawr >= 0x2000) and 'tile_or_other'
        or 'unknown'
      vram:write(string.format('%d\t%d\t%d\t%d\t%04X\t%04X\t%02X\tword_high\t%s\n',
        frame + 1, count.vwr, line, hclock, pc, mawr & 0xFFFF, value, zone))
      mawr = (mawr + 1) & 0xFFFF
    end
    return
  elseif selected == 18 and port == 3 then count.dma = count.dma + 1
  end
  if #trace >= REG_CAP then count.dropped = count.dropped + 1; return end
  -- Only control writes use getState; never one call per VRAM byte.
  local s = emu.getState()
  trace[#trace+1] = {val(s,'vdc.scanline'),val(s,'vdc.hclock'),val(s,'cpu.pc'),
    selected,NAMES[selected] or 'OTHER',port == 2 and 'lo' or 'hi',value,
    val(s,'vdc.hvReg.bgScrollX'),val(s,'vdc.hvReg.bgScrollY'),
    val(s,'vdc.hvLatch.bgScrollX'),val(s,'vdc.hvLatch.bgScrollY'),val(s,'vdc.memAddrWrite')}
end
-- Only the four VDC I/O addresses. A wider range would mistake ordinary RAM
-- addresses whose low two bits happen to match a VDC port.
emu.addMemoryCallback(observePort,emu.callbackType.write,0,0x0003,CPU,MEM)
-- Physical callbacks mark addresses only: do not assume whether value is byte/word.
emu.addMemoryCallback(function(address)
  if not active then return end
  count.physical = count.physical + 1
  dirty[math.floor(address / 2)] = true
end,emu.callbackType.write,0,0xFFFF,CPU,VRAM)
emu.addMemoryCallback(function()
  if active then count.acR = count.acR + 1 end
end,emu.callbackType.read,0x1A00,0x1AFF,CPU,MEM)
emu.addMemoryCallback(function()
  if active then count.acW = count.acW + 1 end
end,emu.callbackType.write,0x1A00,0x1AFF,CPU,MEM)

emu.addEventCallback(function()
  if closed then return end
  local s = emu.getState()
  if not active then
    assert(emu.getMemorySize(VRAM) == 0x10000, 'Unexpected PCE VRAM size')
    assert(type(s['vdc.scanline']) == 'number', 'Missing vdc.scanline; do not infer timing')
    dumpState(s,'baseline_state')
    if type(emu.getRomInfo) == 'function' then
      local ok, info = pcall(emu.getRomInfo)
      if ok and type(info) == 'table' then
        meta:write('\n[rom_info]\n')
        for k,v in pairs(info) do if type(v) ~= 'table' then meta:write(tostring(k)..'='..tostring(v)..'\n') end end
      end
    end
    for w=0,0x7FFF do shadow[w] = readWord(w*2,VRAM) end
    refreshRefs(s); writeSnapshot('baseline_vram')
    local r = s['vdc.currentReg']
    selected = type(r) == 'number' and (r & 31) or nil
    meta:write(('\nexpected_build=0.7.21\nexpected_scene=outside_abandoned_factory\nkey_name=%s\ninitial_cols=%d\ninitial_rows=%d\naudit_every=%d\nmax_frames=%d\n'):format(tostring(KEY),cols,rows,AUDIT_EVERY,MAX_FRAMES))
    meta:write('Interpretation: changes.tsv empty near a MARK + BXR/BYR in registers.tsv = no net BG VRAM change; investigate display-control timing.\n')
    meta:write('BAT changes = tile-map change. referenced_by_prev_bat=1 = a changed word belongs to a tile currently referenced by the prior BAT (not proof it is visible).\n')
    meta:write('vram.tsv VWR destinations show rewritten VRAM. VWR present with no changes = same data rewritten or written-and-restored within the frame.\n')
    meta:write('audit_untracked_changes>0 means the VRAM callback missed a change; use changes.tsv, not callback counts, for the conclusion.\n')
    meta:flush(); active = true
    say('READY. Idle 3 seconds, then R before each menu test. ' .. base)
    return
  end
  frame = frame + 1
  local keyOk, down = false, false
  if KEY then keyOk, down = pcall(emu.isKeyPressed, KEY) end
  down = keyOk and down == true
  local mark = down and not held and 1 or 0
  held = down
  if mark == 1 then marks = marks + 1; say(('MARK %d frame %d'):format(marks,frame)) end
  local dirtyList = {}
  for w in pairs(dirty) do dirtyList[#dirtyList+1] = w end
  table.sort(dirtyList)
  local first,last
  for _,w in ipairs(dirtyList) do
    if first and w ~= last+1 then touches:write(('%d\t%04X\t%04X\n'):format(frame,first,last)); first=nil end
    if not first then first=w end
    last=w
  end
  if first then touches:write(('%d\t%04X\t%04X\n'):format(frame,first,last)) end
  local changed,batChanged,refChanged,missed = 0,0,0,0
  local function check(w,source)
    local v = readWord(w*2,VRAM)
    if shadow[w] ~= v then
      local isBat = w < batWords
      local isRef = refs[math.floor(w/16)] == true
      changes:write(('%d\t%04X\t%04X\t%04X\t%d\t%d\t%s\n'):format(frame,w,shadow[w],v,isBat and 1 or 0,isRef and 1 or 0,source))
      changed=changed+1
      if isBat then batChanged=batChanged+1 end
      if isRef then refChanged=refChanged+1 end
      if source == 'audit_untracked' then missed=missed+1 end
      shadow[w]=v
    end
  end
  for _,w in ipairs(dirtyList) do check(w,'callback') end
  local audit = frame % AUDIT_EVERY == 0 or mark == 1 or count.dma > 0 or frame == MAX_FRAMES
  if audit then
    for w=0,0x7FFF do if not dirty[w] then check(w,'audit_untracked') end end
  end
  for i,t in ipairs(trace) do
    regs:write(('%d\t%d\t'):format(frame,i) .. table.concat(t,'\t') .. '\n')
  end
  frames:write(table.concat({frame,val(s,'vdc.frameCount'),mark,count.acR,count.acW,count.vwr,count.physical,
    #dirtyList,changed,batChanged,refChanged,count.dma,count.unknown,count.dropped,audit and 1 or 0,missed,
    cols,rows,val(s,'vdc.hvReg.bgScrollX'),val(s,'vdc.hvReg.bgScrollY')},'\t') .. '\n')
  if batChanged > 0 or cols ~= val(s,'vdc.hvReg.columnCount') or rows ~= val(s,'vdc.hvReg.rowCount') then refreshRefs(s) end
  totalAuditMissing=totalAuditMissing+missed; totalDrops=totalDrops+count.dropped
  totalDma=totalDma+count.dma; totalUnknown=totalUnknown+count.unknown; totalWrites=totalWrites+count.physical
  if audit then
    writeSnapshot('latest_vram'); dumpState(s,'audit_frame_'..frame)
    for _,f in ipairs(files) do f:flush() end
  end
  if frame % 300 == 0 then say(('frame %d; marks %d; audit-untracked %d; drops %d'):format(frame,marks,totalAuditMissing,totalDrops)) end
  resetCounts()
  if frame >= MAX_FRAMES then finish('frame_limit') end
end,emu.eventType.endFrame)
emu.addEventCallback(function() finish('script_ended') end,emu.eventType.scriptEnded)
say('Loaded. Waiting for first endFrame. No game memory writes.')
