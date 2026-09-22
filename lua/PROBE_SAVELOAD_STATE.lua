-- PROBE_SAVELOAD_STATE - why a soft return to title corrupts the screen
--
-- SUPERSEDED by PROBE_SAVELOAD_STATE_v2.lua.  Kept because it produced the
-- 2026-08-13 dump\saveload_state.tsv run, and that log is only readable next
-- to the code that made it.  Three defects, all in this file:
--
--   memType   CPU-visible reads need emu.memType.pceMemory, not
--             emu.memType.cpu.  hooks/private/cache all came back 00, which
--             reads like "the patch vanished" but is a probe artifact.  Do not
--             conclude anything from those three fields in that log.
--   HELPER    $9CD2 is the retired ac_0.1.5 address; build_ac_dynamic_0_1_9
--             overrides it to $BCD2.  helper_calls stayed 0 while Korean was
--             plainly rendering.
--   mpr       changes every frame from ordinary bank switching, so it was the
--             only field that ever fired and it carried no information.
--
-- Still valid from that run: magic, flags and atlas are AC reads and those
-- worked.  magic AC 15 51 and flags 00 01 02 03 09 were unchanged across the
-- soft return, and all four atlas probes held.
--
-- The bug (인계서 2026-08-13 §8-B)
-- --------------------------------
--   save -> title -> load        screen corrupts
--   power cycle -> load          fine
--
-- Why that asymmetry is the whole clue
-- ------------------------------------
-- The AC helper guards its one-time init with a magic word at AC $10000:
--
--     read AC $10000..$10002; if it is AC 15 51 -> skip init_store entirely
--
-- A power cycle clears Arcade Card RAM, so the magic is gone, init_store runs
-- and reloads directory + state page + template + atlas, then resets every
-- pack-loaded flag to $FF.  A soft return keeps AC RAM, so the magic survives,
-- init is skipped, and the helper *asserts* that everything it needs is still
-- in AC.  Anything that went stale in between has no path back.
--
-- So the question is narrow: across the soft return, which of the states the
-- patch depends on actually changes?  This logs a snapshot and prints only the
-- fields that moved, so one playthrough answers it instead of a debugger loop.
--
-- How to run
-- ----------
--   1. Load the 0.3.1 cue, power-cycle, start the Lua script.
--   2. Play until Korean text renders (reception).      -> baseline appears
--   3. Save.
--   4. Return to title, load that save.                 -> the delta appears
--   5. Send C:\snatcher\dump\saveload_state.tsv
--
-- Reading the result
-- ------------------
--   magic/flags moved     the helper's view of AC went stale -> init guard
--   atlas moved           something overwrote glyph data in AC
--   hooks moved           the patched Track 02 code is no longer installed
--   private moved         $7FEC-$7FFF lookup state survived when it should not
--   nothing moved         the corruption is outside the patch; look at VRAM

local ac   = emu.memType.pceArcadeCardRam
local cpu  = emu.memType.cpu

local OUT  = "C:\\snatcher\\dump\\saveload_state.tsv"
local SAMPLE_EVERY = 30          -- frames; getState() must stay out of hot paths

local ATLAS_AC   = 0x10360
local GLYPH      = 32
local HELPER     = 0x9CD2

-- Atlas probes: first glyph, mid, the old $16000 boundary, and the last glyph
-- of the 1,089-entry atlas.  If only the tail moved we are back in overlap
-- territory; if all four moved something wholesale replaced the region.
local ATLAS_PROBES = { 0, 400, 741, 1088 }

local function hex(value)
  return string.format("%02X", value or 0)
end

local function readRun(base, count, memType)
  local out = {}
  for i = 0, count - 1 do out[#out + 1] = hex(emu.read(base + i, memType)) end
  return table.concat(out, " ")
end

local function snapshot()
  local fields = {}

  -- AC state page: magic then the resident/scene pack-loaded flags.
  fields.magic = readRun(0x10000, 3, ac)
  fields.flags = readRun(0x10003, 5, ac)

  -- AC glyph atlas at four depths.
  local atlas = {}
  for _, index in ipairs(ATLAS_PROBES) do
    atlas[#atlas + 1] = string.format("%d:%s", index,
      readRun(ATLAS_AC + index * GLYPH, 4, ac))
  end
  fields.atlas = table.concat(atlas, "  ")

  -- Track 02 hooks.  These are code, so any movement means the overlay itself
  -- is not the patched one any more.
  fields.hooks = string.format("648C=%s 66E5=%s 674A=%s",
    readRun(0x648C, 3, cpu), readRun(0x66E5, 3, cpu), readRun(0x674A, 3, cpu))

  -- Private lookup state, zero-initialised by the Track 02 patch at install.
  fields.private = readRun(0x7FEC, 20, cpu)

  -- SRT4 header of the current record cache.
  fields.cache = readRun(0x5B80, 16, cpu)

  -- Mesen 2 exposes CPU state under flat keys ("memoryManager.mpr[6]"), with a
  -- nested table on some builds.  MPR 0.1.1/0.1.2 established both paths.
  local state = emu.getState()
  local mpr = {}
  for slot = 0, 7 do
    local value = state[string.format("memoryManager.mpr[%d]", slot)]
    if value == nil and type(state.memoryManager) == "table"
        and type(state.memoryManager.mpr) == "table" then
      value = state.memoryManager.mpr[slot]
    end
    mpr[#mpr + 1] = value and hex(value) or "--"
  end
  fields.mpr = table.concat(mpr, " ")

  return fields
end

local ORDER = { "magic", "flags", "atlas", "hooks", "private", "cache", "mpr" }

local previous = nil
local frames = 0
local helperCalls = 0
local file = io.open(OUT, "w")
file:write("frame\thelper_calls\tfield\tbefore\tafter\n")
file:flush()

local function record(label, before, after)
  file:write(string.format("%d\t%d\t%s\t%s\t%s\n",
    frames, helperCalls, label, before or "", after))
  file:flush()
end

emu.addMemoryCallback(function()
  helperCalls = helperCalls + 1
end, emu.callbackType.exec, HELPER, HELPER, emu.cpuType.pce, cpu)

emu.addEventCallback(function()
  frames = frames + 1
  if frames % SAMPLE_EVERY ~= 0 then return end

  local current = snapshot()
  if previous == nil then
    for _, key in ipairs(ORDER) do record("baseline " .. key, "", current[key]) end
    emu.log("PROBE_SAVELOAD_STATE: baseline captured, now save/title/load")
  else
    for _, key in ipairs(ORDER) do
      if current[key] ~= previous[key] then
        record(key, previous[key], current[key])
        emu.log(string.format("PROBE_SAVELOAD_STATE: %s changed at frame %d",
          key, frames))
      end
    end
  end
  previous = current
end, emu.eventType.endFrame)

emu.log("PROBE_SAVELOAD_STATE armed -> " .. OUT)
