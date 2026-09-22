-- PROBE_SAVELOAD_STATE v5 - who reads the Bank $69 cave, and where does it go?
--
-- Where v1-v4 got to
-- ------------------
--   v1  wrong memType/HELPER; only its AC reads were valid.
--   v2  CD path cleared.  Our loader read nothing during the corruption and
--       the game's $E009 sequence matched the unpatched control exactly.
--   v3  trampoline MPR5 theory killed: a 505-frame helper call produced zero
--       MPR5=$69 frame boundaries.
--   v4  FOUND IT.  The game block-reads the whole cave with inHelper=false:
--         f5771  342 reads $BCD2-$BE27
--         f5772  472 reads $BE28-$BFFF     342+472 = 814 = the cave exactly
--       Original track02.iso has $FF across all 814 bytes, so the game is
--       built to copy $FF from there and gets our helper code instead.
--   census  bank-level relocation is dead.  Every $FF run in the resident
--       banks is already ours; banks $70+ are scene slots CD reloads; the
--       all-zero candidate $6C mapped to MPR6 at frame 172, so it is BSS.
--
-- What this version answers
-- -------------------------
-- Two things that decide the fix:
--
--   1. WHERE the read comes from.  PC at the moment of the first non-helper
--      cave read identifies the routine.  Static search already ruled out a
--      block-transfer instruction (no TIA/TII with src=$BCD2 or len=814), and
--      the split across two frames says it is a paced loop, so the PC is the
--      only way to find it.
--   2. WHERE the bytes go.  Writes are sampled in the same window, so if the
--      destination is the VDC data port ($0002) this is a VRAM tile upload;
--      if it is RAM it is a buffer copy and may be far less load-bearing.
--
-- If the destination turns out to be harmless -- the original copies $FF, after
-- all -- then hooking or neutering that routine becomes an option, and the
-- cave stays usable.  That is worth knowing before shrinking the helper or
-- hunting cold bytes.
--
-- Cost note
-- ---------
-- emu.getState() is called at most once per frame, only on the first
-- non-helper cave read, so it stays out of the hot path the way this project
-- learned to (UI 0.1.62).
--
-- How to run
-- ----------
--   1. Load the 0.3.1 cue, power-cycle, start this script.
--   2. Load your save, play until Korean renders.
--   3. Save in game, return to title, load, reach the corruption.
--   4. Send C:\snatcher\dump\saveload_v5_<time>.tsv
--
-- Reading the result
-- ------------------
--   cave_read rows carry pc=$xxxx  -> that is the routine; disassemble around it
--   port_write rows                -> destination was the VDC data port: VRAM
--   no port_write near the reads    -> plain memory copy; check dst range

local mem = emu.memType.pceMemory
local cpu = emu.memType.cpu

local OUT = string.format("C:\\snatcher\\dump\\saveload_v5_%s.tsv", os.date("%H%M%S"))

local CAVE_LO, CAVE_HI = 0xBCD2, 0xBFFF
local TRAMPOLINE_IN, TRAMPOLINE_OUT = 0x7F88, 0x7F92

-- VDC data port is $0000-$0003 in the I/O page; $0002/$0003 is the data pair.
local VDC_LO, VDC_HI = 0x0000, 0x0003

local function hex4(v) return string.format("$%04X", v or 0) end

local frames, helperCalls = 0, 0
local inHelper = false

local caveReads, caveLo, caveHi, caveInHelper = 0, nil, nil, false
local cavePC = nil
local portWrites = 0

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

emu.addMemoryCallback(function(address)
  caveReads = caveReads + 1
  if caveLo == nil or address < caveLo then caveLo = address end
  if caveHi == nil or address > caveHi then caveHi = address end
  if inHelper then
    caveInHelper = true
  elseif cavePC == nil then
    -- First game-side read this frame: pay for one getState to name the caller.
    local state = emu.getState()
    cavePC = state["cpu.pc"] or (state.cpu and state.cpu.pc)
  end
end, emu.callbackType.read, CAVE_LO, CAVE_HI, emu.cpuType.pce, cpu)

emu.addMemoryCallback(function()
  portWrites = portWrites + 1
end, emu.callbackType.write, VDC_LO, VDC_HI, emu.cpuType.pce, cpu)

emu.addEventCallback(function()
  frames = frames + 1

  if caveReads > 0 then
    record("cave_read", string.format(
      "%d reads  %s-%s  inHelper=%s  pc=%s  vdc_writes_this_frame=%d",
      caveReads, hex4(caveLo), hex4(caveHi), tostring(caveInHelper),
      cavePC and hex4(cavePC) or "-", portWrites))
    if not caveInHelper then
      emu.log(string.format(
        "PROBE v5: GAME READ CAVE f%d  pc=%s  %d reads  vdc_writes=%d",
        frames, cavePC and hex4(cavePC) or "-", caveReads, portWrites))
    end
    caveReads, caveLo, caveHi, caveInHelper, cavePC = 0, nil, nil, false, nil
  end

  portWrites = 0
end, emu.eventType.endFrame)

emu.log(string.format("PROBE v5 armed  cave %s-%s -> %s",
  hex4(CAVE_LO), hex4(CAVE_HI), OUT))
