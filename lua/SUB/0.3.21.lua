-- SUB 0.3.21 -- one-shot UI snapshot at a valid endFrame callback.
-- Load while the reception action menu is visible.  Read-only to emulation.

local MEM  = emu.memType.pceMemory
local AC   = emu.memType.pceArcadeCardRam
local VRAM = emu.memType.pceVideoRam
local OUT = string.format('C:/snatcher/dump/sub_0_3_21_ui_frame_%s.tsv',
                          os.date('%Y%m%d_%H%M%S'))
local done = false

local function hex(at, count, kind)
  local t = {}
  for i = 0, count - 1 do
    t[#t + 1] = string.format('%02X', emu.read(at + i, kind) or 0)
  end
  return table.concat(t, ' ')
end

emu.addEventCallback(function()
  if done then return end
  done = true
  local f = assert(io.open(OUT, 'w'))
  f:write('name\taddress\tbytes\thex\n')
  f:write(string.format('AC_STATE\t10000\t32\t%s\n', hex(0x10000, 0x20, AC)))
  f:write(string.format('CPU_CACHE\t5B80\t704\t%s\n', hex(0x5B80, 0x2C0, MEM)))
  f:write(string.format('SATB\t2000\t512\t%s\n', hex(0x2000, 0x200, VRAM)))
  -- Full 64 KiB byte-visible VRAM half.  This contains every pattern seen in
  -- the reception action UI and avoids guessing its cache address again.
  f:write(string.format('VRAM\t0000\t65536\t%s\n', hex(0x0000, 0x10000, VRAM)))
  f:close()
  emu.log('SUB 0.3.21 FRAME SNAPSHOT PASS -- read-only')
  emu.log('  output: ' .. OUT)
end, emu.eventType.endFrame)

emu.log('SUB 0.3.21 loaded -- UI frame snapshot / read-only')
emu.log('  메뉴가 보이는 상태에서 다음 프레임 끝에 한 번 저장한다')
