-- SUB 0.3.25 -- VRAM $2C00-$2DFF writer trace (read-only).
-- Load before Power Cycle.  Run skip/no-skip to the reception action menu,
-- then Stop.  Records every VDC write to word $1600-$16FF and its CPU PC.

local MEM  = emu.memType.pceMemory
local VRAM = emu.memType.pceVideoRam
local CPU  = emu.memType.cpu
local OUT = string.format('C:/snatcher/dump/sub_0_3_25_writer_%s.tsv',
                          os.date('%Y%m%d_%H%M%S'))
local f = assert(io.open(OUT, 'w'))
f:write('frame\tseq\tword\tbyte_addr\tpc\tvalue\tinc\tsector\n')
f:flush()

local TARGET_LO, TARGET_HI = 0x1600, 0x16FF
local frame, seq = 0, 0
local reg, mawr, inc, low = 0, 0, 1, nil
local pcs, first, last = {}, nil, nil

local function state()
  local ok, s = pcall(emu.getState)
  return (ok and s) or {}
end

emu.addMemoryCallback(function(_, value)
  reg = (value or 0) & 0x1F
end, emu.callbackType.write, 0x0000, 0x0000, emu.cpuType.pce, MEM)

emu.addMemoryCallback(function(_, value)
  low = value or 0
end, emu.callbackType.write, 0x0002, 0x0002, emu.cpuType.pce, MEM)

emu.addMemoryCallback(function(_, value)
  local word = ((value or 0) << 8) | (low or 0)
  low = nil
  if reg == 0x00 then
    mawr = word
    return
  end
  if reg == 0x05 then
    local selector = (word >> 11) & 3
    inc = ({[0]=1,[1]=32,[2]=64,[3]=128})[selector] or 1
    return
  end
  if reg ~= 0x02 then return end

  local at = mawr
  mawr = (mawr + inc) & 0xFFFF
  if at < TARGET_LO or at > TARGET_HI then return end

  local s = state()
  local pc = s['cpu.pc'] or s['cpu.programCounter'] or s['pc'] or 0
  local sector = s['cdrom.scsi.sector'] or -1
  seq = seq + 1
  pcs[pc] = (pcs[pc] or 0) + 1
  local item = {frame=frame, seq=seq, word=at, pc=pc, value=word, sector=sector}
  first = first or item
  last = item
  f:write(string.format('%d\t%d\t%04X\t%04X\t%04X\t%04X\t%d\t%d\n',
    frame, seq, at, at * 2, pc, word, inc, sector))
  f:flush()
end, emu.callbackType.write, 0x0003, 0x0003, emu.cpuType.pce, MEM)

emu.addEventCallback(function()
  frame = frame + 1
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  f:write('# summary\n')
  f:write(string.format('# writes\t%d\n', seq))
  if first then
    f:write(string.format('# first\tf=%d word=%04X pc=%04X sector=%d\n',
      first.frame, first.word, first.pc, first.sector))
    f:write(string.format('# last\tf=%d word=%04X pc=%04X sector=%d\n',
      last.frame, last.word, last.pc, last.sector))
  end
  local list = {}
  for pc, count in pairs(pcs) do list[#list + 1] = {pc=pc,count=count} end
  table.sort(list, function(a,b) return a.count > b.count end)
  for _, item in ipairs(list) do
    f:write(string.format('# pc\t%04X\t%d\n', item.pc, item.count))
  end
  local bytes = {}
  for i = 0, 0x1FF do
    bytes[#bytes + 1] = string.format('%02X', emu.read(0x2C00 + i, VRAM) or 0)
  end
  f:write('# final\t' .. table.concat(bytes, ' ') .. '\n')
  f:close()
  emu.log(string.format('SUB 0.3.25 saved: writes=%d -> %s', seq, OUT))
end, emu.eventType.scriptEnded)

emu.log('SUB 0.3.25 loaded -- VRAM $2C00-$2DFF writer trace / read-only')
emu.log('  Power Cycle -> 스킵 또는 노스킵 -> 접수처 액션 메뉴 -> Stop')
emu.log('  output: ' .. OUT)
