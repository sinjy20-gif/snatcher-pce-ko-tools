-- SUB 0.3.22 -- exact reception UI renderer snapshot.
-- Load before opening/redrawing the reception action menu.  Read-only.

local MEM  = emu.memType.pceMemory
local AC   = emu.memType.pceArcadeCardRam
local VRAM = emu.memType.pceVideoRam
local CPU  = emu.memType.cpu
local OUT = string.format('C:/snatcher/dump/sub_0_3_22_ui_exact_%s.tsv',
                          os.date('%Y%m%d_%H%M%S'))
local done = false

local function hex(at, count, kind)
  local t = {}
  for i = 0, count - 1 do
    t[#t + 1] = string.format('%02X', emu.read(at + i, kind) or 0)
  end
  return table.concat(t, ' ')
end

emu.addMemoryCallback(function()
  if done then return end
  local ptr = (emu.read(0x3471, MEM) or 0) | ((emu.read(0x3472, MEM) or 0) << 8)
  if ptr ~= 0x3499 and ptr ~= 0x349A then return end
  done = true
  local f = assert(io.open(OUT, 'w'))
  f:write('name\taddress\tbytes\thex\n')
  f:write(string.format('AC_STATE\t10000\t32\t%s\n', hex(0x10000, 0x20, AC)))
  f:write(string.format('CPU_CACHE\t5B80\t704\t%s\n', hex(0x5B80, 0x2C0, MEM)))
  f:write(string.format('SATB\t2000\t512\t%s\n', hex(0x2000, 0x200, VRAM)))
  f:write(string.format('VRAM\t0000\t65536\t%s\n', hex(0x0000, 0x10000, VRAM)))
  f:close()
  emu.log(string.format('SUB 0.3.22 EXACT SNAPSHOT PASS ptr=$%04X', ptr))
  emu.log('  output: ' .. OUT)
end, emu.callbackType.exec, 0x66E5, 0x66E5, emu.cpuType.pce, CPU)

emu.log('SUB 0.3.22 loaded -- exact reception UI snapshot / read-only')
emu.log('  접수처 액션 메뉴를 열거나 커서를 움직여 다시 그리면 한 번 저장한다')
