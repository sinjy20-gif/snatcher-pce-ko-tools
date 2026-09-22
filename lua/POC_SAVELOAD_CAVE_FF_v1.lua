-- POC_SAVELOAD_CAVE_FF v1
--
-- Runtime-only proof for the KO 0.3.1 save -> title -> load corruption.
-- It does not modify the disc or AC layout.  When the original game-side
-- decompressor reads CPU $BCD2-$BFFF as source data, return the original byte
-- value ($FF) instead of the Bank $69 helper byte currently stored there.
-- Helper execution/data reads are left untouched.
--
-- Expected result: the previously corrupted screen is clean.  If it is, the
-- permanent fix can guard the decompressor's LDA ($12),Y at $7171.

local mem = emu.memType.pceMemory
local cpu = emu.memType.cpu

local CAVE_LO, CAVE_HI = 0xBCD2, 0xBFFF
local TRAMPOLINE_IN, TRAMPOLINE_OUT = 0x7F88, 0x7F92

local inHelper = false
local substituted = 0
local firstAddress = nil
local lastAddress = nil

emu.addMemoryCallback(function()
  inHelper = true
end, emu.callbackType.exec, TRAMPOLINE_IN, TRAMPOLINE_IN, emu.cpuType.pce, cpu)

emu.addMemoryCallback(function()
  inHelper = false
end, emu.callbackType.exec, TRAMPOLINE_OUT, TRAMPOLINE_OUT, emu.cpuType.pce, cpu)

emu.addMemoryCallback(function(address, value)
  if inHelper then return value end

  substituted = substituted + 1
  if firstAddress == nil then
    firstAddress = address
    emu.log(string.format(
      "CAVE FF POC: substitution started at $%04X (original helper byte %02X)",
      address, value or 0))
  end
  lastAddress = address
  return 0xFF
end, emu.callbackType.read, CAVE_LO, CAVE_HI, emu.cpuType.pce, cpu)

emu.addEventCallback(function()
  if substituted > 0 then
    emu.drawString(4, 4, string.format(
      "CAVE FF POC: %d bytes, $%04X-$%04X",
      substituted, firstAddress or 0, lastAddress or 0), 0xFFFFFFFF, 0xC0000000)
  end
end, emu.eventType.endFrame)

emu.log("CAVE FF POC armed for $BCD2-$BFFF")

