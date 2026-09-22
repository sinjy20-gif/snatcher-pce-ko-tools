-- AC CPU roundtrip verifier for AC CPU Roundtrip 0.1.71.
-- Lua seeds Arcade Card RAM directly; the patched HuC6280 routine must read
-- it through $1A00 and copy it to WRAM $3F00-$3F0F.

local ac = emu.memType.pceArcadeCardRam
local cpu = emu.memType.cpu
local pattern = {}
local done = false
local execSeen = false
local caveSeen = false
local frames = 0
local portLog = 0

for i = 0, 15 do
  pattern[i] = (0x31 + i * 0x17) & 0xFF
  emu.write(i, pattern[i], ac)
end

local function check()
  frames = frames + 1
  if done or frames < 30 then return end
  local same = true
  local got = {}
  for i = 0, 15 do
    got[i] = emu.read(0x1000 + i, ac) or 0
    if got[i] ~= pattern[i] then same = false end
  end
  if same then
    done = true
    emu.log("AC CPU ROUNDTRIP PASS: HuC6280 copied AC $000000 to AC $001000 through $1A00/$1A10")
  elseif frames % 300 == 0 then
    local s = emu.getState()
    local mpr2 = (s["memoryManager.mpr[2]"] or -1)
    emu.log(string.format("AC CPU roundtrip waiting: AC[001000]=%02X expected=%02X cave=%s exec=%s MPR2=%02X", got[0], pattern[0], caveSeen and "yes" or "no", execSeen and "yes" or "no", mpr2))
  end
end

emu.addEventCallback(check, emu.eventType.endFrame)
emu.addMemoryCallback(function()
  if not execSeen then
    execSeen = true
    emu.log("AC CPU roundtrip: execution reached $5F30")
  end
end, emu.callbackType.exec, 0x5F30, 0x5F30, emu.cpuType.pce, cpu)
emu.addMemoryCallback(function()
  if not caveSeen then
    caveSeen = true
    local s = emu.getState()
    local mpr2 = (s["memoryManager.mpr[2]"] or -1)
    local mpr0 = (s["memoryManager.mpr[0]"] or -1)
    emu.log(string.format("AC CPU roundtrip: execution reached cave $5BB3, MPR0=%02X MPR2=%02X", mpr0, mpr2))
    local cave = {}
    local rom = emu.memType.pcePrgRom
    for i = 0, 15 do cave[#cave + 1] = emu.read(0x5BB3 + i, rom) or 0 end
    emu.log("AC PRG-ROM cave bytes: " .. table.concat((function()
      local out = {}
      for i, v in ipairs(cave) do out[i] = string.format("%02X", v) end
      return out
    end)(), " "))
    local function dumpRom(label, base)
      local out = {}
      for i = 0, 15 do out[#out + 1] = string.format("%02X", emu.read(base + i, rom) or 0) end
      emu.log(label .. ": " .. table.concat(out, " "))
    end
    dumpRom("AC PRG-ROM bank68 candidate D1BB3", 0xD1BB3)
    dumpRom("AC PRG-ROM bank68 candidate 7D3B3", 0x7D3B3)
    local card = emu.memType.pceCardRam
    local out = {}
    for i = 0, 15 do out[#out + 1] = string.format("%02X", emu.read(0x1BB3 + i, card) or 0) end
    emu.log("PCE Card RAM $1BB3 bytes: " .. table.concat(out, " "))
    local tail = {}
    for i = 70, 81 do tail[#tail + 1] = string.format("%02X", emu.read(0x1BB3 + i, card) or 0) end
    emu.log("PCE Card RAM cave tail +70: " .. table.concat(tail, " "))
  end
end, emu.callbackType.exec, 0x5BB3, 0x5BB3, emu.cpuType.pce, cpu)

emu.addMemoryCallback(function(address, value)
  if portLog < 40 then
    portLog = portLog + 1
    emu.log(string.format("AC PORT WRITE addr=%04X val=%02X", address, value))
  end
end, emu.callbackType.write, 0x1A00, 0x1A1F, emu.cpuType.pce, cpu)

emu.addMemoryCallback(function(address, value)
  if portLog < 40 then
    portLog = portLog + 1
    emu.log(string.format("AC PORT READ addr=%04X val=%02X", address, value or 0))
  end
end, emu.callbackType.read, 0x1A00, 0x1A1F, emu.cpuType.pce, cpu)
emu.displayMessage("AC CPU Roundtrip", "Lua pattern seeded; waiting for CPU copy to AC $001000")
emu.log("AC_CPU_ROUNDTRIP_VERIFY loaded: AC[000000..00000F] seeded")
