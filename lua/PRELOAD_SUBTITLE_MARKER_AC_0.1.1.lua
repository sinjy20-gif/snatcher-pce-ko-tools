-- Preload the marker renderer payload into the reserved AC subtitle region.
-- This is a POC bridge only: it writes Arcade Card RAM $1C0500.. and never
-- touches CPU RAM, VDC, BIOS ROM, or the disc.  The final runtime replaces
-- this with the disc/AC loader.

local INPUT = "C:/snatcher/build/subtitles/marker_engine_v0_1_1.bin"
local AC_BASE = 0x1C0500
local ac = emu.memType.pceArcadeCardRam
local f = assert(io.open(INPUT, "rb"), "missing marker engine: " .. INPUT)
local data = f:read("a"); f:close()
assert(#data > 0 and #data <= 0x480, "invalid marker engine size")
for i = 1, #data do emu.write(AC_BASE + i - 1, string.byte(data, i), ac) end
local ok = true
for i = 1, #data do
  if (emu.read(AC_BASE + i - 1, ac) or -1) ~= string.byte(data, i) then ok = false; break end
end
assert(ok, "AC marker payload read-back mismatch")
emu.log(string.format("SUBTITLE MARKER AC PRELOAD PASS: %d B -> $%06X", #data, AC_BASE))
