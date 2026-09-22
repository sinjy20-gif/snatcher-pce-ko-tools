-- CENSUS_BANK_USAGE 0.1.1 - which Super CD-ROM² RAM banks does the game map?
--
-- Why this exists
-- ---------------
-- The Bank $69 helper cave failed on 2026-08-13.  It was chosen because the
-- game never executes $BCD2-$BFFF and the original bytes are 100% $FF.  Both
-- true; neither was freeness.  PROBE_SAVELOAD_STATE_v4 caught the game
-- block-reading all 814 bytes in two frames and drawing them, which is the
-- save->title->load corruption (인계서 §8-B).
--
-- A better criterion
-- ------------------
-- The CPU cannot touch a bank it has not mapped into one of MPR0-7.  So a bank
-- the game never maps is safe by construction -- no read census needed, no
-- "$FF means unused" guesswork.  Our trampoline already maps its own bank
-- ($7F88: LDA #$69, TAM #$20), so the helper can live in any bank we choose.
--
-- The candidate
-- -------------
-- Static scan of track02.iso, banks $68-$87:
--
--     bank 6C   8192 bytes, exactly one distinct value: 00
--     bank 60   same          bank 61   same
--
-- $6C sits between $6B and $6D, which are both dense code.
--
-- All-zero cuts both ways, and this must not be repeated as "it looks free":
--
--     unloaded    the program image never covers this bank -> genuinely free
--     BSS         zero-initialised work RAM -> the game writes it constantly,
--                 and it would be the worst possible place for the helper
--
-- The disc image cannot distinguish these; only the census can.  If $6C is
-- BSS it will show up mapped almost immediately.  Note this is the same shape
-- of mistake as the $FF cave -- an absence of content read as an absence of
-- ownership -- so the burden of proof is on the candidate.
--
-- Meanwhile every $FF run in the resident banks is already ours:
--     bank 68  $1BB3-$1FFF  1101 B   record cache + preloader
--     bank 69  $1CD2-$1FFF   814 B   the failed cave
--     bank 6A  $1F50-$1FFF   176 B   wrapper + sector loader + state
-- and the large $FF runs in banks $70+ repeat at identical offsets across
-- banks 70,78,79,7A,7B,7C,7D -- scene-slot padding that CD reloads overwrite.
--
-- Known limitation - read this before trusting a "never mapped" result
-- -------------------------------------------------------------------
-- This samples MPR0-7 once per frame, so it sees sustained mappings (a CD load
-- into a bank lasts many frames) but can miss a mapping held for a few
-- instructions.  PROBE v3 demonstrated the undercount directly: 72 helper
-- calls produced only 7 sampled MPR5=$69 frames.  So:
--
--     bank appears  ->  proof it IS used.  Reliable.
--     bank absent   ->  suggestive, NOT proof.  Needs a long, wide session.
--
-- Treat an absent bank as a candidate to test, not a finding.  That confusion
-- is what produced this bug in the first place.
--
-- How to run
-- ----------
--   1. Load the 0.3.1 cue, power-cycle, start this script.
--   2. Play widely: title, load, several rooms, menus, item screens, save,
--      return to title, load again, and any scene transition you can reach.
--      Coverage is the whole result.
--   3. Read C:\snatcher\dump\bank_usage_<time>.tsv, rewritten every 300 frames.

local OUT = string.format("C:\\snatcher\\dump\\bank_usage_%s.tsv", os.date("%H%M%S"))

local BANK_LO, BANK_HI = 0x60, 0x87
local REPORT_EVERY = 300
local WATCH = { [0x60] = true, [0x61] = true, [0x6C] = true }

-- seen[bank] = { count, firstFrame, slots = {slot -> count} }
local seen = {}
local frames = 0

local function mprOf(state, slot)
  local value = state[string.format("memoryManager.mpr[%d]", slot)]
  if value == nil and type(state.memoryManager) == "table"
      and type(state.memoryManager.mpr) == "table" then
    value = state.memoryManager.mpr[slot]
  end
  return value
end

local function report()
  local file = io.open(OUT, "w")
  file:write("frame\tbank\tstatus\tsamples\tfirst_frame\tslots\n")
  for bank = BANK_LO, BANK_HI do
    local hit = seen[bank]
    local slots = {}
    if hit then
      for slot = 0, 7 do
        if hit.slots[slot] then
          slots[#slots + 1] = string.format("MPR%d:%d", slot, hit.slots[slot])
        end
      end
    end
    file:write(string.format("%d\t$%02X\t%s\t%d\t%s\t%s\n",
      frames, bank,
      hit and "mapped" or "never-seen",
      hit and hit.count or 0,
      hit and tostring(hit.firstFrame) or "",
      table.concat(slots, " ")))
  end
  file:close()

  local free = {}
  for bank = BANK_LO, BANK_HI do
    if not seen[bank] then free[#free + 1] = string.format("$%02X", bank) end
  end
  emu.log(string.format("CENSUS f%d: never-seen banks: %s",
    frames, #free > 0 and table.concat(free, " ") or "(none)"))
end

emu.addEventCallback(function()
  frames = frames + 1
  local state = emu.getState()
  for slot = 0, 7 do
    local bank = mprOf(state, slot)
    if bank and bank >= BANK_LO and bank <= BANK_HI then
      local hit = seen[bank]
      if hit == nil then
        hit = { count = 0, firstFrame = frames, slots = {} }
        seen[bank] = hit
        if WATCH[bank] then
          emu.log(string.format(
            "CENSUS: candidate bank $%02X WAS MAPPED at frame %d (MPR%d) -- not free",
            bank, frames, slot))
        end
      end
      hit.count = hit.count + 1
      hit.slots[slot] = (hit.slots[slot] or 0) + 1
    end
  end
  if frames % REPORT_EVERY == 0 then report() end
end, emu.eventType.endFrame)

emu.log(string.format("CENSUS_BANK_USAGE armed  banks $%02X-$%02X -> %s",
  BANK_LO, BANK_HI, OUT))
emu.log("candidates $60 $61 $6C are all-zero in track02.iso; watching whether they map")
