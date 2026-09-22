-- MPR 0.1.2 - scene-identity probe
--
-- Where 0.1.0 / 0.1.1 got to
-- --------------------------
--   PRELOAD $5E40  MPR6 tracks location: 74 reception, 71 HQ interior,
--                  75 director's office.  Reception resolved to scene 111800
--                  9 times out of 9 across two separate power cycles, so the
--                  value is real and reproducible, not a coincidence of timing.
--   DECODER $7272  MPR6 = 7E/7F while decoding, and 81 on the item screen.
--   CDREAD  $E006  zero page reads correctly now ($20F0, not $00F0), but
--                  $F8-$FA only ever alternates between two values and the
--                  numbers are far too large for a 40,000-sector track.  Not
--                  the LBA.  Parked.
--
-- Why this version stops asking master.tsv
-- ----------------------------------------
-- Confirming which scene MPR6=75 means requires ground truth, and the only
-- ground truth on hand was snatcher_ko_master.tsv -- whose scene data being
-- unreliable is the original problem.  Measuring a new ruler with the broken
-- ruler cannot settle anything: for MPR6=75, 40 of 93 captured lines are absent
-- from master entirely and the rest match a dozen scenes each.
--
-- So identify the page by its CONTENT instead.  Every row now carries 48 bytes
-- read through the MPR5/MPR6 windows.  Offline, search extraction/track02.iso
-- for those bytes: the offset where they land IS the CD page, which is exactly
-- what the scene packs are named after (scene_111800).  No master.tsv involved.
--
-- This also survives bank rotation.  The bank number is a proxy that holds only
-- while the game happens to keep a page mapped; the content fingerprint is the
-- page itself, so it stays correct even if 75 later means a different scene.
--
-- Run on the PATCHED disc.  Play a few scenes; the more distinct locations the
-- better, since each one contributes an independent fingerprint to match.

local mem = emu.memType.pceMemory
local outputPath = "C:\\snatcher\\dump\\mpr_scene_probe.tsv"

-- $7272 runs per decoder call, not per captured line.  Sampling every call puts
-- a getState() in a hot callback, which this project already learned to avoid
-- (UI 0.1.62: "콜백 안에서 getState() 를 부르지 않는다").
local DECODER_SAMPLE_EVERY = 16

-- MPR5 covers CPU $A000-$BFFF and MPR6 covers $C000-$DFFF.  NibbleDecoder pairs
-- a script page with the text page in the next bank, so sampling both catches
-- whichever half is mapped.
local MPR5_WINDOW = 0xA000
local MPR6_WINDOW = 0xC000
local FINGERPRINT_BYTES = 48

local sequence = 0
local decoderCalls = 0
local lastDecoderSignature = nil

local function byte(address)
  return emu.read(address, mem) or 0
end

local function word(address)
  return byte(address) + byte(address + 1) * 256
end

local function state()
  local ok, s = pcall(emu.getState)
  if ok and s then return s end
  return {}
end

local function currentFrame()
  return state()["frameCount"] or 0
end

local function readMprFrom(s)
  local banks = {}
  for slot = 0, 7 do
    local value = s[string.format("memoryManager.mpr[%d]", slot)]
    if value == nil then value = s[string.format("mpr[%d]", slot)] end
    if value == nil and type(s.memoryManager) == "table" and type(s.memoryManager.mpr) == "table" then
      value = s.memoryManager.mpr[slot]
    end
    banks[slot] = value or -1
  end
  return banks
end

local function mprText(banks)
  local parts = {}
  for slot = 0, 7 do
    parts[#parts + 1] = banks[slot] < 0 and "??" or string.format("%02X", banks[slot])
  end
  return table.concat(parts, "\t")
end

-- Read through the CPU window, so whatever bank MPR currently selects is what
-- gets sampled -- no need to know how banks map to physical addresses.
local function fingerprint(windowBase)
  local out = {}
  for offset = 0, FINGERPRINT_BYTES - 1 do
    out[#out + 1] = string.format("%02X", byte(windowBase + offset))
  end
  return table.concat(out)
end

-- $FF terminates, 0x3F cap -- identical to runtime_text_audit's readString, so
-- a sample is byte-for-byte what the real collector would record.
local function readSourceHex(pointer)
  local out = {}
  for offset = 0, 0x3F do
    local value = byte(pointer + offset)
    if value == 0xFF then break end
    out[#out + 1] = string.format("%02X", value)
  end
  return table.concat(out)
end

-- The decoder pointer roams across windows ($488D, $C095, $E782, $8D83 all
-- appeared), so the interesting bank is whichever one the pointer currently
-- lands in -- not a fixed window.  Slot = ptr >> 13.
local function focusSlot(pointer)
  if pointer == nil or pointer == 0 then return -1 end
  return math.floor(pointer / 0x2000)
end

local header = "kind\tseq\tframe\tmpr0\tmpr1\tmpr2\tmpr3\tmpr4\tmpr5\tmpr6\tmpr7\tptr\tdetail\tsource_hex\tmpr5_head\tmpr6_head\tfocus_slot\tfocus_bank\tfocus_head\n"

local function ensureHeader()
  local existing = io.open(outputPath, "rb")
  local needsHeader = existing == nil
  if existing ~= nil then
    local length = existing:seek("end") or 0
    existing:close()
    needsHeader = length == 0
  end
  if not needsHeader then return end
  local file = io.open(outputPath, "wb")
  if file == nil then
    emu.log("MPR PROBE: cannot open " .. outputPath)
    return
  end
  file:write(header)
  file:close()
end

local function emit(kind, banks, pointer, detail, sourceHex)
  sequence = sequence + 1
  local slot = focusSlot(pointer)
  local focusBank = slot >= 0 and banks[slot] or -1
  local focusHead = slot >= 0 and fingerprint(slot * 0x2000) or ""
  local line = string.format("%s\t%d\t%d\t%s\t%04X\t%s\t%s\t%s\t%s\t%d\t%s\t%s\n",
    kind, sequence, currentFrame(), mprText(banks), pointer or 0, detail or "",
    sourceHex or "", fingerprint(MPR5_WINDOW), fingerprint(MPR6_WINDOW),
    slot, focusBank < 0 and "??" or string.format("%02X", focusBank), focusHead)
  local file = io.open(outputPath, "ab")
  if file ~= nil then
    file:write(line)
    file:close()
  end
  emu.log(string.format("MPR %s[%d] MPR5=%s MPR6=%s ptr=%04X %s",
    kind, sequence,
    banks[5] < 0 and "??" or string.format("%02X", banks[5]),
    banks[6] < 0 and "??" or string.format("%02X", banks[6]),
    pointer or 0, detail or ""))
end

-- $5E40: the patch preloader, i.e. exactly where runtime_text_audit captures.
local function onPreloader(address, value)
  local rendererPointer = word(0x3471)
  if rendererPointer ~= 0x3619 and rendererPointer ~= 0x349A then return end
  local pointer = rendererPointer == 0x349A and 0x3499 or rendererPointer
  local sourceHex = readSourceHex(pointer)
  if #sourceHex == 0 then return end
  emit("PRELOAD", readMprFrom(state()), rendererPointer,
    rendererPointer == 0x349A and "channel=UI" or "channel=TEXT", sourceHex)
end

local function onDecoder(address, value)
  decoderCalls = decoderCalls + 1
  if decoderCalls % DECODER_SAMPLE_EVERY ~= 1 then return end
  local banks = readMprFrom(state())
  local signature = mprText(banks)
  if signature == lastDecoderSignature then return end
  lastDecoderSignature = signature
  emit("DECODER", banks, word(0x360D),
    string.format("calls=%d renderer=%04X", decoderCalls, word(0x3471)), "")
end

ensureHeader()

emu.addMemoryCallback(onPreloader, emu.callbackType.exec, 0x5E40, 0x5E40, emu.cpuType.pce, mem)
emu.addMemoryCallback(onDecoder, emu.callbackType.exec, 0x7272, 0x7272, emu.cpuType.pce, mem)

emu.log("MPR 0.1.2 loaded - hooks: $5E40 preloader, $7272 decoder")
emu.log("Now fingerprinting the MPR5/MPR6 windows for offline track02 matching.")
emu.log("MPR PROBE output: " .. outputPath)
