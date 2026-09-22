-- Preload the exact 0.3.0-uitest SRT4 backing-store image into Arcade Card RAM.
-- The patched HuC6280 $7F88 routine performs all runtime reads through $1A00.

local imagePath = [[C:\snatcher\build\patch\0.3.1-ac-runtime\ac_backing_store\arcade_card_preload_2mb.bin]]
local ac = emu.memType.pceArcadeCardRam
local cpu = emu.memType.cpu
local file, err = io.open(imagePath, "rb")
if not file then error("cannot open AC preload image: " .. tostring(err)) end
local data = file:read("*a")
file:close()

for address = 0, #data - 1 do
  emu.write(address, string.byte(data, address + 1), ac)
end

local acLoads = 0
local cdReads = 0
emu.addMemoryCallback(function()
  acLoads = acLoads + 1
  if acLoads <= 8 then emu.log(string.format("AC SRT4 loader hit #%d", acLoads)) end
end, emu.callbackType.exec, 0x7F88, 0x7F88, emu.cpuType.pce, cpu)
emu.addMemoryCallback(function()
  cdReads = cdReads + 1
  if cdReads <= 8 then emu.log(string.format("BIOS CD_READ #%d", cdReads)) end
end, emu.callbackType.exec, 0xE009, 0xE009, emu.cpuType.pce, cpu)

emu.displayMessage("AC Backing Store", string.format("Preloaded %d bytes", #data))
emu.log(string.format("AC backing store preloaded: %d bytes from %s", #data, imagePath))
