-- SUB 0.3.20 -- immediate reception UI sprite-pattern snapshot.
-- Pause/Stop with the action menu visible, then load this file once.
-- Read-only: it only writes a dump file on the host.

local MEM  = emu.memType.pceMemory
local AC   = emu.memType.pceArcadeCardRam
local VRAM = emu.memType.pceVideoRam
local OUT = string.format('C:/snatcher/dump/sub_0_3_20_ui_snapshot_%s.tsv',
                          os.date('%Y%m%d_%H%M%S'))

local function hex(at, count, kind)
  local t = {}
  for i = 0, count - 1 do
    t[#t + 1] = string.format('%02X', emu.read(at + i, kind) or 0)
  end
  return table.concat(t, ' ')
end

local f = assert(io.open(OUT, 'w'))
f:write('name\taddress\tbytes\thex\n')
f:write(string.format('AC_STATE\t10000\t32\t%s\n', hex(0x10000, 0x20, AC)))
f:write(string.format('CPU_CACHE\t5B80\t704\t%s\n', hex(0x5B80, 0x2C0, MEM)))
f:write(string.format('SATB\t2000\t512\t%s\n', hex(0x2000, 0x200, VRAM)))
-- The captured reception SATB uses patterns $0000-$00A0.  In Mesen byte
-- addressing those and their large-sprite continuations fit below $4000.
f:write(string.format('SPRITE_PATTERNS\t0000\t16384\t%s\n', hex(0x0000, 0x4000, VRAM)))
f:close()

emu.log('SUB 0.3.20 SNAPSHOT PASS -- read-only')
emu.log('  output: ' .. OUT)
