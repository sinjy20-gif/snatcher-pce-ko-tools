-- CENSUS_COLD_REGIONS 0.1.1 - find address ranges the game never touches
--
-- Why this exists
-- ---------------
-- The Bank $69 helper cave at $BCD2-$BFFF was chosen because the game never
-- *executes* it and the original bytes are 100% $FF.  Both true.  But on
-- 2026-08-13 PROBE_SAVELOAD_STATE_v4 caught the game block-*reading* all 814
-- bytes of it in two frames ($BCD2-$BE27 then $BE28-$BFFF) and copying them
-- out -- so our helper code was being drawn as tile data.  That is the
-- save->title->load corruption (인계서 §8-B).
--
-- "Not executed" and "filled with $FF" are not freeness.  The project already
-- said so about other gaps and it was not applied here:
--
--     not allocated is not proven free
--     no execution/reference census ... therefore not a free-space finding
--
-- So this measures the real thing: every read, write and execute in a range,
-- and reports what was never touched at all.
--
-- What to census
-- --------------
-- The resident program banks are full.  Static scan of track02.iso, banks
-- $68-$6A, found only three $FF runs and all three are already ours:
--
--     bank 68  $1BB3-$1FFF  1101 B   record cache + preloader
--     bank 69  $1CD2-$1FFF   814 B   the cave that just failed
--     bank 6A  $1F50-$1FFF   176 B   font wrapper + sector loader + state
--
-- Banks $70+ have far more $FF, but the identical $0940-$1018 run repeats
-- across banks 70,78,79,7A,7B,7C,7D -- structural padding in scene slots that
-- CD reloads overwrite.  A resident helper cannot live there.
--
-- That leaves WRAM $2000-$3FFF: always mapped through MPR1=$F8 and executable.
-- The game keeps variables there, so only measurement can say which parts are
-- cold.
--
-- Cost warning
-- ------------
-- Three callbacks over 8 KiB of the busiest RAM in the machine.  The callback
-- body is a single table store on purpose; anything more makes the emulator
-- crawl.  Expect it to run slower than full speed regardless.
--
-- How to run
-- ----------
--   1. Load the 0.3.1 cue, power-cycle, start this script.
--   2. Play widely -- title, load, reception, a few rooms, menus, save,
--      return to title, load again.  Coverage is the whole point: an address
--      is only "cold" with respect to what you exercised.
--   3. Press the report interval or just read the dump; it rewrites every
--      600 frames to C:\snatcher\dump\cold_wram_<time>.tsv
--
-- Reading the result
-- ------------------
-- Runs are listed longest first with what touched them.  A run needs to be
-- >= 709 bytes to hold the current helper.  Treat any candidate as a
-- hypothesis, not a finding, until it has survived a long session that
-- includes the paths where the game does bulk copies.

local cpu = emu.memType.cpu

local LO, HI = 0x2000, 0x3FFF
local REPORT_EVERY = 600
local NEED = 709                    -- current helper_code_bytes

local OUT = string.format("C:\\snatcher\\dump\\cold_wram_%s.tsv", os.date("%H%M%S"))

-- touched[addr] = bitmask 1 read, 2 write, 4 exec
local touched = {}
for a = LO, HI do touched[a] = 0 end

local frames = 0

emu.addMemoryCallback(function(address)
  touched[address] = touched[address] | 1
end, emu.callbackType.read, LO, HI, emu.cpuType.pce, cpu)

emu.addMemoryCallback(function(address)
  touched[address] = touched[address] | 2
end, emu.callbackType.write, LO, HI, emu.cpuType.pce, cpu)

emu.addMemoryCallback(function(address)
  touched[address] = touched[address] | 4
end, emu.callbackType.exec, LO, HI, emu.cpuType.pce, cpu)

local function report()
  local runs = {}
  local start = nil
  for a = LO, HI + 1 do
    local cold = (a <= HI) and touched[a] == 0
    if cold and start == nil then
      start = a
    elseif not cold and start ~= nil then
      runs[#runs + 1] = { start, a - 1, a - start }
      start = nil
    end
  end
  table.sort(runs, function(x, y) return x[3] > y[3] end)

  local file = io.open(OUT, "w")
  file:write("frame\tstart\tend\tsize\tfits_helper\n")
  local coldTotal = 0
  for _, r in ipairs(runs) do
    coldTotal = coldTotal + r[3]
    file:write(string.format("%d\t$%04X\t$%04X\t%d\t%s\n",
      frames, r[1], r[2], r[3], r[3] >= NEED and "YES" or ""))
  end
  file:close()

  local best = runs[1]
  emu.log(string.format(
    "CENSUS f%d: %d cold bytes in %d runs; largest %s",
    frames, coldTotal, #runs,
    best and string.format("$%04X-$%04X (%d B)%s", best[1], best[2], best[3],
      best[3] >= NEED and "  <- fits the helper" or "") or "none"))
end

emu.addEventCallback(function()
  frames = frames + 1
  if frames % REPORT_EVERY == 0 then report() end
end, emu.eventType.endFrame)

emu.log(string.format("CENSUS_COLD_REGIONS armed  $%04X-$%04X -> %s", LO, HI, OUT))
emu.log("play widely; a run is only cold for the paths you actually exercised")
