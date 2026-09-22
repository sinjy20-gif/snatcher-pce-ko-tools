-- PROBE_SAVELOAD_STATE v2 - why a soft return to title corrupts the screen
--
-- The bug (인계서 2026-08-13 §8-B)
-- --------------------------------
--   save -> title -> load        screen corrupts
--   power cycle -> load          fine
--
-- What v1 got wrong (do not repeat)
-- ---------------------------------
--   memType   CPU-visible reads need emu.memType.pceMemory.  v1 used
--             emu.memType.cpu and every hook/cache/private field came back 00,
--             which reads like "the patch vanished" but is just a bad probe.
--   HELPER    $9CD2 is the retired ac_0.1.5 address.  build_ac_dynamic_0_1_9
--             overrides it to $BCD2 (MPR5, mask $20), so the exec callback
--             counted 0 calls while Korean was plainly rendering.
--   zero page MPR1=$F8 maps RAM to $2000, so BIOS CD arguments live at $20F8,
--             not $00F8 (인계서 §5).
--   mpr       changes every frame from ordinary bank switching.  Kept for
--             context, excluded from change detection, or it drowns the log.
--
-- The hypothesis this version tests
-- --------------------------------
-- The AC helper's sector loader points the BIOS at Track 24, reads a record,
-- then restores the Track 02 base.  The body handoff is explicit that failing
-- to restore "leaves subsequent original-disc reads on the wrong base".  A
-- soft return reloads scene graphics from CD; if the base is still Track 24 at
-- that moment the game decodes our translation payload as tile data, which is
-- exactly what the corrupted screen looks like.  So every $E006/$E009 call is
-- logged with its arguments: the smoking gun is a graphics-sized read issued
-- while the base is Track 24.
--
-- How to run
-- ----------
--   1. Load the 0.3.1 cue, power-cycle, start this script.
--   2. Play until Korean renders.                       -> baseline
--   3. Save.
--   4. Return to title, load that save, reach the corruption.
--   5. Send C:\snatcher\dump\saveload_state_v2.tsv

local mem = emu.memType.pceMemory          -- CPU-visible reads
local ac  = emu.memType.pceArcadeCardRam
local cpu = emu.memType.cpu                -- exec callbacks only

-- Versioned with the script: v1's log is the only record of that run and must
-- not be overwritten by a rerun here.
local OUT = "C:\\snatcher\\dump\\saveload_state_v2.tsv"
local SAMPLE_EVERY = 30

local ATLAS_AC = 0x10360
local GLYPH    = 32
local HELPER   = 0xBCD2
local ZP       = 0x2000                    -- zero page window (MPR1 = $F8)

local BIOS_CD_BASE = 0xE006
local BIOS_CD_READ = 0xE009

-- Track 24 base is emitted as 03 96 8D 00 01, Track 02 as 00 10 4E 00 01.
local TRACK24 = "03 96 8D 00 01"
local TRACK02 = "00 10 4E 00 01"

local ATLAS_PROBES = { 0, 400, 741, 1088 }

local function hex(value) return string.format("%02X", value or 0) end

local function readRun(base, count, memType)
  local out = {}
  for i = 0, count - 1 do out[#out + 1] = hex(emu.read(base + i, memType)) end
  return table.concat(out, " ")
end

local frames, helperCalls, cdCalls = 0, 0, 0
local lastBase = "?"

local file = io.open(OUT, "w")
file:write("frame\thelper\tcd\tfield\tbefore\tafter\n")
file:flush()

local function record(label, before, after)
  file:write(string.format("%d\t%d\t%d\t%s\t%s\t%s\n",
    frames, helperCalls, cdCalls, label, before or "", after))
  file:flush()
end

local function snapshot()
  local f = {}
  f.magic = readRun(0x10000, 3, ac)
  f.flags = readRun(0x10003, 5, ac)

  local atlas = {}
  for _, index in ipairs(ATLAS_PROBES) do
    atlas[#atlas + 1] = string.format("%d:%s", index,
      readRun(ATLAS_AC + index * GLYPH, 4, ac))
  end
  f.atlas = table.concat(atlas, "  ")

  f.hooks = string.format("648C=%s 66E5=%s 674A=%s",
    readRun(0x648C, 3, mem), readRun(0x66E5, 3, mem), readRun(0x674A, 3, mem))
  f.private = readRun(0x7FEC, 20, mem)
  f.cache = readRun(0x5B80, 16, mem)
  f.cdbase = lastBase
  return f
end

-- mpr is deliberately absent: it changes constantly and told us nothing in v1.
local WATCH = { "magic", "flags", "atlas", "hooks", "private", "cache", "cdbase" }

local previous = nil

emu.addMemoryCallback(function()
  helperCalls = helperCalls + 1
end, emu.callbackType.exec, HELPER, HELPER, emu.cpuType.pce, cpu)

-- Every CD base change, with the five argument bytes.  Infrequent enough to
-- log unconditionally, and the sequence is the whole point.
emu.addMemoryCallback(function()
  cdCalls = cdCalls + 1
  local args = readRun(ZP + 0xF8, 5, mem)
  local name = (args == TRACK24 and "TRACK24")
            or (args == TRACK02 and "TRACK02") or "other"
  lastBase = name
  record("cd_base", "", string.format("%s  args=%s", name, args))
end, emu.callbackType.exec, BIOS_CD_BASE, BIOS_CD_BASE, emu.cpuType.pce, cpu)

-- Every read, with the sector, length and BIOS destination type.  Destination
-- 4 is the helper's AC path; anything else is the game reading for itself, and
-- one of those landing while the base says TRACK24 is the failure.
emu.addMemoryCallback(function()
  cdCalls = cdCalls + 1
  local sectors = hex(emu.read(ZP + 0xF8, mem))
  local sector = string.format("%s%s",
    hex(emu.read(ZP + 0xFE, mem)), hex(emu.read(ZP + 0xFD, mem)))
  local dest = hex(emu.read(ZP + 0xFF, mem))
  record("cd_read", "", string.format(
    "base=%s sectors=%s sector=%s dest=%s", lastBase, sectors, sector, dest))
end, emu.callbackType.exec, BIOS_CD_READ, BIOS_CD_READ, emu.cpuType.pce, cpu)

emu.addEventCallback(function()
  frames = frames + 1
  if frames % SAMPLE_EVERY ~= 0 then return end

  local current = snapshot()
  if previous == nil then
    for _, key in ipairs(WATCH) do record("baseline " .. key, "", current[key]) end
    emu.log("PROBE v2: baseline captured, now save/title/load")
  else
    for _, key in ipairs(WATCH) do
      if current[key] ~= previous[key] then
        record(key, previous[key], current[key])
        emu.log(string.format("PROBE v2: %s changed at frame %d", key, frames))
      end
    end
  end
  previous = current
end, emu.eventType.endFrame)

emu.log(string.format("PROBE v2 armed  helper=$%04X  -> %s", HELPER, OUT))
