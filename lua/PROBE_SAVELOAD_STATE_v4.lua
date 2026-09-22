-- PROBE_SAVELOAD_STATE v4 - does the game read our Bank $69 helper cave as data?
--
-- Where v1/v2/v3 got to
-- ---------------------
--   v1  wrong memType and HELPER address; only its AC reads were valid.
--   v2  CD path cleared.  Our loader made zero reads of its own during the
--       corruption, and the game's $E009 sector sequence was byte-identical
--       to the unpatched control run.
--   control  unpatched disc, save -> title -> load: clean.  The bug is ours.
--   v3  killed the "trampoline holds MPR5 across interrupts" theory: a helper
--       call lasting 505 frames produced zero MPR5=$69 frame boundaries, so
--       the BIOS remaps during transfers and the window is not what I assumed.
--
--       But v3 found something better.  MPR5 = $69 at seven frame boundaries,
--       every one of them with inHelper=false -- twice before the helper had
--       ever run.  The game maps bank $69 itself, in consecutive-frame pairs
--       that look like a graphics transfer.
--
-- What this version tests
-- -----------------------
-- Our helper lives in an 814-byte cave at $BCD2-$BFFF inside bank $69.  That
-- cave was verified as space the original game never *executes*.  Nothing
-- verified that the game never *reads* it.  If the game blocks a region of
-- bank $69 out to VRAM, our helper bytes become tile data: garbage graphics
-- with the text layer untouched, which is the reported symptom exactly.
--
-- So: a read callback across the cave.  Any hit while inHelper is false is the
-- game touching our code as data, and that is the bug.
--
-- Reads are counted, not logged one by one -- a block transfer would produce
-- hundreds and flood the file.  Each frame that saw reads emits one row with
-- the count and the address range touched.
--
-- How to run
-- ----------
--   1. Load the 0.3.1 cue, power-cycle, start this script.
--   2. Load your save, play until Korean renders.
--   3. Save in game, return to title, load, reach the corruption.
--   4. Send the C:\snatcher\dump\saveload_v4_<time>.tsv named on load.
--
-- Reading the result
-- ------------------
--   cave_read rows with inHelper=false   confirmed: the game reads our cave
--     and the row's frame should line up with when the screen broke
--   no such rows                          the cave is innocent; next suspect
--     is $64B3 fractional glyph shift or $674A -> $5E20

local mem = emu.memType.pceMemory
local ac  = emu.memType.pceArcadeCardRam
local cpu = emu.memType.cpu

local OUT = string.format("C:\\snatcher\\dump\\saveload_v4_%s.tsv", os.date("%H%M%S"))

local CAVE_LO, CAVE_HI = 0xBCD2, 0xBFFF
local TRAMPOLINE_IN, TRAMPOLINE_OUT = 0x7F88, 0x7F92
local HELPER_BANK = 0x69
local ATLAS_AC, GLYPH = 0x10360, 32
local SAMPLE_EVERY = 30

local function hex(v) return string.format("%02X", v or 0) end

local function readRun(base, count, memType)
  local out = {}
  for i = 0, count - 1 do out[#out + 1] = hex(emu.read(base + i, memType)) end
  return table.concat(out, " ")
end

local function mprOf(state, slot)
  local value = state[string.format("memoryManager.mpr[%d]", slot)]
  if value == nil and type(state.memoryManager) == "table"
      and type(state.memoryManager.mpr) == "table" then
    value = state.memoryManager.mpr[slot]
  end
  return value
end

local frames, helperCalls = 0, 0
local inHelper = false

-- Per-frame accumulator, flushed once at end of frame.
local caveReads, caveLo, caveHi, caveInHelper = 0, nil, nil, false

local file = io.open(OUT, "w")
file:write("frame\thelper\tfield\tvalue\n")
file:flush()

local function record(field, value)
  file:write(string.format("%d\t%d\t%s\t%s\n", frames, helperCalls, field, value))
  file:flush()
end

emu.addMemoryCallback(function()
  helperCalls = helperCalls + 1
  inHelper = true
end, emu.callbackType.exec, TRAMPOLINE_IN, TRAMPOLINE_IN, emu.cpuType.pce, cpu)

emu.addMemoryCallback(function()
  inHelper = false
end, emu.callbackType.exec, TRAMPOLINE_OUT, TRAMPOLINE_OUT, emu.cpuType.pce, cpu)

-- The measurement.  Keep this callback as cheap as possible: it can fire
-- hundreds of times in a single transfer.
emu.addMemoryCallback(function(address)
  caveReads = caveReads + 1
  if caveLo == nil or address < caveLo then caveLo = address end
  if caveHi == nil or address > caveHi then caveHi = address end
  if inHelper then caveInHelper = true end
end, emu.callbackType.read, CAVE_LO, CAVE_HI, emu.cpuType.pce, cpu)

local previous = nil
local WATCH = { "magic", "flags", "atlas" }

emu.addEventCallback(function()
  frames = frames + 1

  if caveReads > 0 then
    record("cave_read", string.format(
      "%d reads  $%04X-$%04X  inHelper=%s",
      caveReads, caveLo or 0, caveHi or 0, tostring(caveInHelper)))
    if not caveInHelper then
      emu.log(string.format(
        "PROBE v4: GAME READ THE CAVE at frame %d (%d reads $%04X-$%04X)",
        frames, caveReads, caveLo or 0, caveHi or 0))
    end
    caveReads, caveLo, caveHi, caveInHelper = 0, nil, nil, false
  end

  local state = emu.getState()
  if mprOf(state, 5) == HELPER_BANK then
    record("mpr5_bank69", string.format("inHelper=%s", tostring(inHelper)))
  end

  if frames % SAMPLE_EVERY ~= 0 then return end

  local f = {}
  f.magic = readRun(0x10000, 3, ac)
  f.flags = readRun(0x10003, 5, ac)
  local atlas = {}
  for _, i in ipairs({ 0, 400, 741, 1088 }) do
    atlas[#atlas + 1] = string.format("%d:%s", i, readRun(ATLAS_AC + i * GLYPH, 4, ac))
  end
  f.atlas = table.concat(atlas, "  ")

  if previous == nil then
    for _, k in ipairs(WATCH) do record("baseline " .. k, f[k]) end
    emu.log("PROBE v4: baseline captured -> " .. OUT)
  else
    for _, k in ipairs(WATCH) do
      if f[k] ~= previous[k] then record(k, f[k]) end
    end
  end
  previous = f
end, emu.eventType.endFrame)

emu.log(string.format("PROBE v4 armed  cave $%04X-$%04X -> %s", CAVE_LO, CAVE_HI, OUT))
