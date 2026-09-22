-- PROBE_PACK_RELOAD 0.1.2 - is a pack still being re-read from CD?
--
-- Where 0.1.1 got to
-- ------------------
-- It proved the scene-slot thrash on the 0.3.1 build: scene_111800 loaded from
-- CD seven times and scene_10F800 five, all to $50000, alternating as a menu
-- and its dialogue displaced each other.  0.3.2 gives every pack its own AC
-- address and its own loaded-flag, so this version checks the re-reads are gone.
--
-- Two defects fixed here
-- ----------------------
--   noise   0.1.1 logged every $E009, the game's own reads included.  The
--           helper keeps PACK_ID in its Bank $69 scratch, so outside the helper
--           that address holds ordinary game data and the log filled with rows
--           like "pack_id 225 dest $B852D6".  The trampoline $7F88/$7F92 now
--           gates it and only our transfers are recorded.
--   table   the id->name map was the 15-pack 0.3.1 build.  0.3.2 has 25, so
--           every name was wrong.  Regenerated below from its manifest.
--
-- The initial load has no pack: init_store sets the destination and chunk count
-- but never PACK_ID, so it appears with whatever id was left in scratch and a
-- $000000 destination.  It is labelled rather than counted as pack 0.
--
-- How to run
-- ----------
--   1. Load the 0.3.2 cue, power-cycle, start this script.
--   2. Reach the reception, open the action menu, close it, open it again.
--      Repeat, then walk to another room and come back.
--   3. Watch the console; a pack loading a second time prints immediately.
--
-- Reading the result
-- ------------------
--   no "loaded again" lines     0.3.2 holds; packs stay resident in AC
--   a pack loading again        its flag is not holding.  Check that the
--                               runtime's 3 + pack_id offset still matches what
--                               build_packs_compact wrote, and that the flag
--                               area has not run into the metadata table
--   "went to $X but manifest says $Y"   builder and runtime disagree

local mem = emu.memType.pceMemory
local cpu = emu.memType.cpu

local OUT = string.format("C:\\snatcher\\dump\\pack_reload_v2_%s.tsv", os.date("%H%M%S"))

local BIOS_CD_READ = 0xE009
local TRAMPOLINE_IN, TRAMPOLINE_OUT = 0x7F88, 0x7F92
local LEFT, DEST_LO, DEST_MID, DEST_HI, PACK_ID = 0xBFE2, 0xBFE4, 0xBFE5, 0xBFE6, 0xBFE8

-- Generated from build/patch/0.3.2/manifest.json.  A rebuild can renumber
-- these; regenerate rather than hand-editing.
local PACK = {
  [0] = { name = "speaker", kind = "res", dest = 0x1A000 },
  [1] = { name = "ui", kind = "res", dest = 0x1C000 },
  [2] = { name = "small_scenes", kind = "res", dest = 0x3A000 },
  [3] = { name = "shared", kind = "res", dest = 0x3B800 },
  [4] = { name = "scene_0C9800", kind = "scene", dest = 0x50000 },
  [5] = { name = "scene_0BB800", kind = "scene", dest = 0x51000 },
  [6] = { name = "scene_10F800", kind = "scene", dest = 0x54000 },
  [7] = { name = "scene_119800", kind = "scene", dest = 0x56000 },
  [8] = { name = "scene_121800", kind = "scene", dest = 0x5E800 },
  [9] = { name = "scene_111800", kind = "scene", dest = 0x62000 },
  [10] = { name = "scene_17B800", kind = "scene", dest = 0x67800 },
  [11] = { name = "scene_17A000", kind = "scene", dest = 0x68800 },
  [12] = { name = "scene_0BA000", kind = "scene", dest = 0x69000 },
  [13] = { name = "scene_0CF800", kind = "scene", dest = 0x69800 },
  [14] = { name = "scene_117800", kind = "scene", dest = 0x6A800 },
  [15] = { name = "scene_110000", kind = "scene", dest = 0x6B800 },
  [16] = { name = "scene_112000", kind = "scene", dest = 0x6C000 },
  [17] = { name = "scene_0E7800", kind = "scene", dest = 0x6C800 },
  [18] = { name = "scene_1B5000", kind = "scene", dest = 0x6D000 },
  [19] = { name = "scene_110800", kind = "scene", dest = 0x6D800 },
  [20] = { name = "scene_10F000", kind = "scene", dest = 0x6E000 },
  [21] = { name = "scene_179800", kind = "scene", dest = 0x6E800 },
  [22] = { name = "scene_111000", kind = "scene", dest = 0x6F000 },
  [23] = { name = "scene_160800", kind = "scene", dest = 0x6F800 },
  [24] = { name = "scene_0BC000", kind = "scene", dest = 0x70000 },
}

local frames, reads, skipped = 0, 0, 0
local inHelper = false
local loads = {}
local lastKey = nil

local file = io.open(OUT, "w")
file:write("frame\tread#\tpack_id\tpack\tdest\tchunks_left\tload#\n")
file:flush()

emu.addMemoryCallback(function() inHelper = true end,
  emu.callbackType.exec, TRAMPOLINE_IN, TRAMPOLINE_IN, emu.cpuType.pce, cpu)
emu.addMemoryCallback(function() inHelper = false end,
  emu.callbackType.exec, TRAMPOLINE_OUT, TRAMPOLINE_OUT, emu.cpuType.pce, cpu)

emu.addMemoryCallback(function()
  if not inHelper then
    skipped = skipped + 1
    return
  end
  reads = reads + 1

  local id = emu.read(PACK_ID, mem) or 0xFF
  local dest = (emu.read(DEST_LO, mem) or 0)
    | ((emu.read(DEST_MID, mem) or 0) << 8)
    | ((emu.read(DEST_HI, mem) or 0) << 16)
  local left = emu.read(LEFT, mem) or 0

  local entry = PACK[id]
  local isInit = (dest == 0)
  local name = isInit and "(initial load)" or (entry and entry.name or ("id" .. id))

  -- Consecutive reads are chunks of one transfer; a new key means a new load.
  local key = isInit and "init" or id
  local isNew = (key ~= lastKey)
  lastKey = key
  local count = ""
  if isNew and not isInit then
    loads[id] = (loads[id] or 0) + 1
    count = tostring(loads[id])
  end

  file:write(string.format("%d\t%d\t%d\t%s\t$%05X\t%d\t%s\n",
    frames, reads, id, name, dest, left, count))
  file:flush()

  if isNew and not isInit then
    if loads[id] > 1 then
      emu.log(string.format("PACK_RELOAD f%d: %s loaded again (#%d) -> $%05X",
        frames, name, loads[id], dest))
    elseif entry and dest ~= entry.dest then
      emu.log(string.format(
        "PACK_RELOAD f%d: %s went to $%05X but the manifest says $%05X",
        frames, name, dest, entry.dest))
    end
  end
end, emu.callbackType.exec, BIOS_CD_READ, BIOS_CD_READ, emu.cpuType.pce, cpu)

emu.addEventCallback(function()
  frames = frames + 1
  if frames % 1800 ~= 0 then return end
  local parts, again = {}, 0
  for id = 0, 63 do
    if loads[id] then
      parts[#parts + 1] = string.format("%s x%d",
        (PACK[id] and PACK[id].name) or id, loads[id])
      if loads[id] > 1 then again = again + 1 end
    end
  end
  emu.log(string.format("PACK_RELOAD f%d (%d ours, %d game reads skipped): %s%s",
    frames, reads, skipped,
    #parts > 0 and table.concat(parts, ", ") or "no pack loads yet",
    again > 0 and string.format("  <- %d pack(s) reloaded", again) or ""))
end, emu.eventType.endFrame)

emu.log("PROBE_PACK_RELOAD 0.1.2 armed -> " .. OUT)
emu.log("only helper transfers are logged; the game's own CD reads are skipped")
