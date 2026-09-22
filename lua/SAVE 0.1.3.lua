-- SAVE 0.1.3 - detect Korean runtime bytes being read as graphics data
-- Read-only, low-overhead probe for KO 0.2.26.
--
-- SAVE 0.1.2 proved that the fixed runtime code and hooks remain byte-exact
-- after save.  This probe tests the next hypothesis: the game maps the banks
-- containing those patches and reads the patched bytes as data while writing
-- graphics to the VDC.

local mem = emu.memType.pceMemory
local cpu = emu.memType.cpu
local OUT = string.format("C:\\snatcher\\dump\\SAVE_0.1.3_%s.tsv", os.date("%H%M%S"))

local RANGES = {
  { name = "record_tail_helper", lo = 0x5E20, hi = 0x5E3F },
  { name = "preloader",          lo = 0x5E40, hi = 0x5FF1 },
  { name = "font_hook",          lo = 0x648C, hi = 0x648E },
  { name = "fractional",         lo = 0x64B3, hi = 0x64E3 },
  { name = "renderer_hook",      lo = 0x66E5, hi = 0x66E7 },
  { name = "space_hook",         lo = 0x674A, hi = 0x674C },
  { name = "font_loader_state",  lo = 0x7F50, hi = 0x7FFF },
}

local function mprOf(state, slot)
  local value = state[string.format("memoryManager.mpr[%d]", slot)]
  if value == nil and type(state.memoryManager) == "table"
      and type(state.memoryManager.mpr) == "table" then
    value = state.memoryManager.mpr[slot]
  end
  return value
end

local file = assert(io.open(OUT, "w"))
file:write("frame\trange\treads\tlo\thi\tpc\tmpr2\tmpr3\tvdc_writes\n")
file:flush()

local frame = 0
local vdcWrites = 0
local stats = {}
for _, range in ipairs(RANGES) do
  stats[range.name] = { reads = 0, lo = nil, hi = nil, pc = nil,
                        mpr2 = nil, mpr3 = nil }
end

-- VDC ports $0000-$0003.  A high write count in the same frame as reads from
-- a patched range is direct evidence of a graphics-transfer context.
emu.addMemoryCallback(function()
  vdcWrites = vdcWrites + 1
end, emu.callbackType.write, 0x0000, 0x0003, emu.cpuType.pce, cpu)

for _, range in ipairs(RANGES) do
  local r = range
  emu.addMemoryCallback(function(address)
    local s = stats[r.name]
    s.reads = s.reads + 1
    if s.lo == nil or address < s.lo then s.lo = address end
    if s.hi == nil or address > s.hi then s.hi = address end
    if s.pc == nil then
      local state = emu.getState()
      s.pc = state["cpu.pc"] or (state.cpu and state.cpu.pc) or 0
      s.mpr2 = mprOf(state, 2) or 0
      s.mpr3 = mprOf(state, 3) or 0
    end
  end, emu.callbackType.read, r.lo, r.hi, emu.cpuType.pce, cpu)
end

emu.addEventCallback(function()
  frame = frame + 1
  for _, range in ipairs(RANGES) do
    local s = stats[range.name]
    if s.reads > 0 then
      file:write(string.format(
        "%d\t%s\t%d\t$%04X\t$%04X\t$%04X\t$%02X\t$%02X\t%d\n",
        frame, range.name, s.reads, s.lo or 0, s.hi or 0, s.pc or 0,
        s.mpr2 or 0, s.mpr3 or 0, vdcWrites))
      file:flush()
      if vdcWrites > 0 then
        emu.log(string.format(
          "SAVE 0.1.3: DATA READ %s $%04X-$%04X (%d), VDC writes=%d, PC=$%04X",
          range.name, s.lo or 0, s.hi or 0, s.reads, vdcWrites, s.pc or 0))
      end
      s.reads, s.lo, s.hi, s.pc, s.mpr2, s.mpr3 = 0, nil, nil, nil, nil, nil
    end
  end
  vdcWrites = 0
end, emu.eventType.endFrame)

emu.log("SAVE 0.1.3 armed (read-only data-read/VDC correlation): " .. OUT)
