-- Passive System Card ROM-bank probe for the subtitle renderer payload.
--
-- The lifecycle POC's $FEC4 cave has only 49 B left.  The next renderer is
-- copied from a separate all-FF System Card ROM bank through a temporary MPR6
-- mapping, so first record the live MPR values at the proven AD_PLAY hook.

local OUT = "C:/snatcher/dump/probe_bios_rom_bank_0_1_0.tsv"
local mem, cpu = emu.memType.pceMemory, emu.memType.cpu
local file = assert(io.open(OUT, "w"))
file:write("frame\tpc\tmpr0\tmpr1\tmpr2\tmpr3\tmpr4\tmpr5\tmpr6\tmpr7\tkey\n")
local frame, rows = 0, 0

local function value(s, n)
  return s[string.format("memoryManager.mpr[%d]", n)]
      or s[string.format("mpr[%d]", n)] or 0
end

local function matched()
  return (emu.read(0x22A6, mem) or 0) == 0
     and (emu.read(0x22A7, mem) or 0) == 0x68
     and (emu.read(0x22AA, mem) or 0) == 0x0E
end

emu.addMemoryCallback(function()
  if rows > 0 or not matched() then return end
  local s = emu.getState() or {}
  local m = {}
  for n = 0, 7 do m[n + 1] = value(s, n) end
  file:write(string.format("%d\tF61A\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\tE6800_0E\n",
    frame, table.unpack(m)))
  file:flush(); rows = rows + 1
  emu.log(string.format("BIOS ROM bank: MPR6=$%02X MPR7=$%02X", m[7], m[8]))
end, emu.callbackType.exec, 0xF61A, 0xF61A, emu.cpuType.pce, cpu)

emu.addEventCallback(function() frame = frame + 1 end, emu.eventType.endFrame)
emu.addEventCallback(function() file:close() end, emu.eventType.scriptEnded)
emu.log("PROBE_BIOS_ROM_BANK 0.1.0 loaded (passive)")
emu.log("  run the proven E6800_0E line once; output: " .. OUT)
