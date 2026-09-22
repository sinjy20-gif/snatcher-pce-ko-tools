-- PROBE_SAVELOAD_STATE v3 - does the helper hold MPR5 across a frame boundary?
--
-- Where v1/v2 got to
-- ------------------
--   v1  memType/HELPER wrong.  Only its AC reads (magic, flags, atlas) were
--       valid, and those were unchanged across the soft return.
--   v2  fixed those.  Established, on the patched disc: hooks intact, record
--       cache always a valid SDR4, and the helper made 42 calls with ZERO CD
--       reads of its own ($E006 never fired).  The 10 $E009 reads were the
--       game's; the control run on the unpatched disc produced the identical
--       sector sequence (18/3600, 03/7E00, 17/BE03, 0C/6E00 ...).
--       So the CD path is not involved.
--   control  unpatched disc, save -> title -> load: no corruption.
--       The bug is ours.
--
-- What this version tests
-- -----------------------
-- The $7F88 trampoline swaps MPR5 to bank $69 for the whole helper call:
--
--   $7F88  TMA #$20        save MPR5
--   $7F8D  TAM #$20        MPR5 <- $69     game data at $A000-$BFFF displaced
--   $7F8F  JSR $BCD2       helper, CD reads included
--   $7F96  TAM #$20        restore
--
-- There is no SEI.  If an interrupt fires while MPR5 is $69 -- and a CD read
-- inside the helper can last ~188 ms, which is many frames -- the game's
-- handler reads our helper bank instead of its graphics.  Garbage tiles with
-- intact text is exactly that signature.
--
-- The decisive measurement is one line: is MPR5 equal to $69 at a frame
-- boundary?  Normal play should never show it.  If the corruption run does,
-- the trampoline is the bug.
--
-- Output is timestamped per run.  v2 overwrote one dump with the next and the
-- corrupted-run log was lost; see lua\README.md.
--
-- How to run
-- ----------
--   1. Load the 0.3.1 cue, power-cycle, start this script.
--   2. Load your save, play until Korean renders.
--   3. Save in game, return to title, load, reach the corruption.
--   4. Send the C:\snatcher\dump\saveload_v3_<time>.tsv it names on load.

local mem = emu.memType.pceMemory
local ac  = emu.memType.pceArcadeCardRam
local cpu = emu.memType.cpu

local OUT = string.format("C:\\snatcher\\dump\\saveload_v3_%s.tsv", os.date("%H%M%S"))

local SAMPLE_EVERY = 30
local ATLAS_AC, GLYPH = 0x10360, 32
local HELPER_BANK = 0x69

local TRAMPOLINE_IN  = 0x7F88   -- before the swap
local TRAMPOLINE_OUT = 0x7F92   -- helper returned, MPR5 still $69
local HELPER         = 0xBCD2

-- Reading $648C/$7FEC only means anything while MPR3 maps bank $6A, and
-- $5B80 while MPR2 maps $68.  v2 sampled blind and produced 14 "changes"
-- that were nothing but bank rotation.
local MPR2_EXPECT, MPR3_EXPECT = 0x68, 0x6A

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
local inHelper, helperEnteredAt = false, 0
local straddleCount = 0

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
  helperEnteredAt = frames
end, emu.callbackType.exec, TRAMPOLINE_IN, TRAMPOLINE_IN, emu.cpuType.pce, cpu)

emu.addMemoryCallback(function()
  if inHelper and frames > helperEnteredAt then
    record("helper_span", string.format(
      "call lasted %d frames (entered f%d)", frames - helperEnteredAt, helperEnteredAt))
  end
  inHelper = false
end, emu.callbackType.exec, TRAMPOLINE_OUT, TRAMPOLINE_OUT, emu.cpuType.pce, cpu)

local previous = nil
local WATCH = { "magic", "flags", "atlas", "hooks", "private", "cache" }

emu.addEventCallback(function()
  frames = frames + 1
  local state = emu.getState()
  local mpr5 = mprOf(state, 5)

  -- THE measurement.  A frame boundary reached with our bank still mapped
  -- means the game's frame work ran against displaced data.
  if mpr5 == HELPER_BANK then
    straddleCount = straddleCount + 1
    record("MPR5_STRADDLE", string.format(
      "mpr5=$69 at frame end, inHelper=%s, occurrence #%d",
      tostring(inHelper), straddleCount))
  end

  if frames % SAMPLE_EVERY ~= 0 then return end

  local mpr2, mpr3 = mprOf(state, 2), mprOf(state, 3)
  local banked = (mpr2 == MPR2_EXPECT and mpr3 == MPR3_EXPECT)

  local f = {}
  f.magic = readRun(0x10000, 3, ac)
  f.flags = readRun(0x10003, 5, ac)
  local atlas = {}
  for _, i in ipairs({ 0, 400, 741, 1088 }) do
    atlas[#atlas + 1] = string.format("%d:%s", i, readRun(ATLAS_AC + i * GLYPH, 4, ac))
  end
  f.atlas = table.concat(atlas, "  ")

  if banked then
    f.hooks = string.format("648C=%s 66E5=%s 674A=%s",
      readRun(0x648C, 3, mem), readRun(0x66E5, 3, mem), readRun(0x674A, 3, mem))
    f.private = readRun(0x7FEC, 20, mem)
    f.cache = readRun(0x5B80, 16, mem)
  else
    f.hooks, f.private, f.cache = "(unbanked)", "(unbanked)", "(unbanked)"
  end

  if previous == nil then
    for _, k in ipairs(WATCH) do record("baseline " .. k, f[k]) end
    record("baseline mpr", string.format("2=%s 3=%s 5=%s",
      hex(mpr2), hex(mpr3), hex(mpr5)))
    emu.log("PROBE v3: baseline captured -> " .. OUT)
  else
    for _, k in ipairs(WATCH) do
      if f[k] ~= previous[k] and f[k] ~= "(unbanked)"
          and previous[k] ~= "(unbanked)" then
        record(k, f[k])
        emu.log(string.format("PROBE v3: %s changed at frame %d", k, frames))
      end
    end
  end
  previous = f
end, emu.eventType.endFrame)

emu.log("PROBE v3 armed -> " .. OUT)
emu.log("watching for MPR5=$69 at frame boundaries")
