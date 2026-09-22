-- PROBE_SAVELOAD_CAVE_CALLER v6
--
-- Purpose
-- -------
-- v4 proved that the game reads Bank $69 CPU $BCD2-$BFFF as data.  v5 saw
-- pc=$7173 but did not capture the mapped code bank, registers, instruction
-- bytes, or stack, so that PC could not be tied to a physical routine.
--
-- This version records a bounded forensic snapshot on the first game-side
-- cave read of each frame and the first 24 game-side reads overall.  It does
-- not patch memory.  Start it on KO 0.3.1, then reproduce:
--
--     in-game save -> return to title -> load -> corrupted screen
--
-- Output: C:\snatcher\dump\saveload_cave_caller_v6_<time>.tsv

local mem = emu.memType.pceMemory
local cpu = emu.memType.cpu

local OUT = string.format(
  "C:\\snatcher\\dump\\saveload_cave_caller_v6_%s.tsv", os.date("%H%M%S"))

local CAVE_LO, CAVE_HI = 0xBCD2, 0xBFFF
local TRAMPOLINE_IN, TRAMPOLINE_OUT = 0x7F88, 0x7F92
local DETAIL_LIMIT = 24

local frames, helperCalls = 0, 0
local inHelper = false
local detailCount = 0
local frameReads, frameLo, frameHi = 0, nil, nil
local frameFirst = nil

local file = assert(io.open(OUT, "w"))
file:write("frame\thelper\tfield\tvalue\n")
file:flush()

local function record(field, value)
  file:write(string.format("%d\t%d\t%s\t%s\n", frames, helperCalls, field, value))
  file:flush()
end

local function stateValue(state, key, fallback)
  local value = state[key]
  if value == nil then return fallback end
  return value
end

local function bytesAt(address, count)
  local out = {}
  for i = 0, count - 1 do
    out[#out + 1] = string.format("%02X", emu.read((address + i) % 0x10000, mem))
  end
  return table.concat(out, " ")
end

local function mpr(state, slot)
  return stateValue(state, string.format("memoryManager.mpr[%d]", slot), 0xFF)
end

local function snapshot(address)
  local state = emu.getState()
  local pc = stateValue(state, "cpu.pc", 0)
  local sp = stateValue(state, "cpu.sp", stateValue(state, "cpu.s", 0))
  local codeStart = (pc - 12) % 0x10000
  local stackStart = 0x2100 + ((sp + 1) % 0x100)
  return string.format(
    "read=$%04X pc=$%04X a=%02X x=%02X y=%02X sp=%02X p=%02X " ..
    "mpr=%02X,%02X,%02X,%02X,%02X,%02X,%02X,%02X " ..
    "code@$%04X=[%s] stack@$%04X=[%s]",
    address, pc,
    stateValue(state, "cpu.a", 0), stateValue(state, "cpu.x", 0),
    stateValue(state, "cpu.y", 0), sp, stateValue(state, "cpu.ps", stateValue(state, "cpu.p", 0)),
    mpr(state, 0), mpr(state, 1), mpr(state, 2), mpr(state, 3),
    mpr(state, 4), mpr(state, 5), mpr(state, 6), mpr(state, 7),
    codeStart, bytesAt(codeStart, 25), stackStart, bytesAt(stackStart, 24))
end

emu.addMemoryCallback(function()
  helperCalls = helperCalls + 1
  inHelper = true
end, emu.callbackType.exec, TRAMPOLINE_IN, TRAMPOLINE_IN, emu.cpuType.pce, cpu)

emu.addMemoryCallback(function()
  inHelper = false
end, emu.callbackType.exec, TRAMPOLINE_OUT, TRAMPOLINE_OUT, emu.cpuType.pce, cpu)

emu.addMemoryCallback(function(address)
  if inHelper then return end

  frameReads = frameReads + 1
  if frameLo == nil or address < frameLo then frameLo = address end
  if frameHi == nil or address > frameHi then frameHi = address end

  if frameFirst == nil then frameFirst = snapshot(address) end
  if detailCount < DETAIL_LIMIT then
    detailCount = detailCount + 1
    record("read_detail", snapshot(address))
  end
end, emu.callbackType.read, CAVE_LO, CAVE_HI, emu.cpuType.pce, cpu)

emu.addEventCallback(function()
  frames = frames + 1
  if frameReads > 0 then
    record("frame_summary", string.format(
      "%d reads $%04X-$%04X first={%s}",
      frameReads, frameLo or 0, frameHi or 0, frameFirst or "-"))
    frameReads, frameLo, frameHi, frameFirst = 0, nil, nil, nil
  end
end, emu.eventType.endFrame)

emu.log("PROBE v6 armed -> " .. OUT)
