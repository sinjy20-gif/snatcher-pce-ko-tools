-- PROBE_BELOW_CACHE 0.1.1 - how far below $5B80 is dead?
--
-- Why
-- ---
-- The Bank $69 helper cave has to be vacated: the game block-reads all 814
-- bytes of $BCD2-$BFFF and uploads them to VRAM (PROBE_SAVELOAD_STATE_v4,
-- 2026-08-13).  Bank-level relocation is exhausted -- every bank $68-$87 gets
-- mapped, and the all-zero candidate $6C mapped to MPR6 within 172 frames.
--
-- So the helper has to fit inside territory we already hold, and the budget
-- lands about 13 bytes short.  Too thin to start a change this size.
--
-- The one lead left
-- -----------------
-- The original $FF run in bank 68 is $5BB3-$5FFF (1,101 B).  The patch already
-- uses $5B80-$5FF1 (1,138 B), so $5B80-$5BB2 -- 51 bytes that were NOT $FF --
-- has been overwritten all along, and the build works.  That content was dead.
--
-- If the dead zone extends further down, the budget opens up.  $5B00-$5B7F
-- alone would turn a 13-byte deficit into a 115-byte margin.
--
-- What this measures
-- ------------------
-- Read, write and execute across $5A00-$5B7F, reported per run so the exact
-- boundary of the dead zone shows up rather than a yes/no.  Nothing in the
-- patch touches this range, so every hit is the game's.
--
-- The lesson from the cave applies here and is the reason this probe exists at
-- all: "not $FF" and "not executed" are both worthless as freeness evidence.
-- Only read+write+exec silence counts, and only for the paths actually played.
--
-- How to run
-- ----------
--   1. Load the 0.3.1 cue, power-cycle, start this script.
--   2. Play as widely as you can stand -- title, load, several rooms, menus,
--      item screens, save, return to title, load again.  A run is only cold
--      with respect to what you exercised.
--   3. Read C:\snatcher\dump\below_cache_<time>.tsv, rewritten every 300
--      frames, or watch the console line.
--
-- Reading the result
-- ------------------
--   cold run reaching up to $5B7F   contiguous with our cache: usable, and the
--                                   run's length is the margin we gain
--   hits high in the range          the dead zone is shallow; take the size it
--                                   actually gives and re-run the budget
--   hits everywhere                 no margin here; the self-contained plan
--                                   needs the lookup redesigned instead

local cpu = emu.memType.cpu

local LO, HI = 0x5A00, 0x5B7F
local REPORT_EVERY = 300
local OUT = string.format("C:\\snatcher\\dump\\below_cache_%s.tsv", os.date("%H%M%S"))

-- touched[addr] = bitmask 1 read, 2 write, 4 exec
local touched = {}
for a = LO, HI do touched[a] = 0 end

local frames = 0
local firstHit = nil

local function mark(address, bit)
  if touched[address] == 0 and firstHit == nil then
    firstHit = string.format("$%04X at frame %d", address, frames)
  end
  touched[address] = touched[address] | bit
end

emu.addMemoryCallback(function(a) mark(a, 1) end,
  emu.callbackType.read, LO, HI, emu.cpuType.pce, cpu)
emu.addMemoryCallback(function(a) mark(a, 2) end,
  emu.callbackType.write, LO, HI, emu.cpuType.pce, cpu)
emu.addMemoryCallback(function(a) mark(a, 4) end,
  emu.callbackType.exec, LO, HI, emu.cpuType.pce, cpu)

local function kindOf(mask)
  local out = {}
  if mask & 1 ~= 0 then out[#out + 1] = "R" end
  if mask & 2 ~= 0 then out[#out + 1] = "W" end
  if mask & 4 ~= 0 then out[#out + 1] = "X" end
  return #out > 0 and table.concat(out) or "-"
end

local function report()
  local runs, start = {}, nil
  for a = LO, HI + 1 do
    local cold = (a <= HI) and touched[a] == 0
    if cold and start == nil then
      start = a
    elseif not cold and start ~= nil then
      runs[#runs + 1] = { start, a - 1, a - start }
      start = nil
    end
  end

  local file = io.open(OUT, "w")
  file:write("frame\tstart\tend\tsize\ttouches_cache\n")
  for _, r in ipairs(runs) do
    file:write(string.format("%d\t$%04X\t$%04X\t%d\t%s\n",
      frames, r[1], r[2], r[3], r[2] == HI and "ADJACENT" or ""))
  end
  file:write("\n# per-16-byte map, . = untouched\n")
  for base = LO, HI, 16 do
    local row = {}
    for a = base, base + 15 do
      row[#row + 1] = touched[a] == 0 and "." or kindOf(touched[a])
    end
    file:write(string.format("# $%04X  %s\n", base, table.concat(row, " ")))
  end
  file:close()

  -- The run that matters is the one ending at $5B7F: only that one is
  -- contiguous with the cache and therefore usable as one block.
  local adjacent = 0
  for _, r in ipairs(runs) do
    if r[2] == HI then adjacent = r[3] end
  end
  emu.log(string.format(
    "BELOW_CACHE f%d: %d cold runs; contiguous with $5B80 = %d B%s",
    frames, #runs, adjacent,
    firstHit and ("  first hit " .. firstHit) or "  no hits yet"))
end

emu.addEventCallback(function()
  frames = frames + 1
  if frames % REPORT_EVERY == 0 then report() end
end, emu.eventType.endFrame)

emu.log(string.format("PROBE_BELOW_CACHE armed  $%04X-$%04X -> %s", LO, HI, OUT))
