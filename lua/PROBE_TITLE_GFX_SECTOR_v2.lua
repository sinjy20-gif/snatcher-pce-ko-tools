-- Snatcher PCE-CD title graphics CD sector probe for Mesen 2
-- Lightweight probe for tracing the CD sector used when the title graphics
-- buffer at $3B00 is being filled.
--
-- Strategy:
--   Watch CPU writes to $3B00-$3B1F.
--   On the first write of a burst, log frame + current CD SCSI sector.
--   Ignore subsequent writes for a short cooldown to avoid log spam.
--
-- Output:
--   C:\snatcher\dump\title_gfx_sector_probe.tsv
--
-- Expected console output:
--   TITLE GFX LOAD[1] frame=xxxx sector=yyyyyy addr=$3B00 value=$xx

local outputPath = "C:\\snatcher\\dump\\title_gfx_sector_probe.tsv"

local START_ADDR = 0x3B00
local END_ADDR   = 0x3B1F

-- Suppress repeated writes belonging to the same transfer burst.
-- 30 frames ~= 0.5 sec at 60 fps.
local COOLDOWN_FRAMES = 30

local sequence = 0
local lastLoggedFrame = -1000000

local function getFrameAndSector()
  local ok, state = pcall(emu.getState)
  if not ok or type(state) ~= "table" then
    return 0, -1
  end

  local frame = state["frameCount"]
  if type(frame) ~= "number" then frame = 0 end

  local sector = state["cdrom.scsi.sector"]
  if type(sector) ~= "number" then sector = -1 end

  return frame, sector
end

local function ensureHeader()
  local existing = io.open(outputPath, "rb")
  local needsHeader = existing == nil

  if existing ~= nil then
    needsHeader = (existing:seek("end") or 0) == 0
    existing:close()
  end

  if not needsHeader then return true end

  local file, err = io.open(outputPath, "ab")
  if file == nil then
    emu.log("TITLE GFX PROBE ERROR opening " .. outputPath .. ": " .. tostring(err))
    return false
  end

  file:write("event_id\tsequence\tframe\tsector\taddress\tvalue\n")
  file:flush()
  file:close()
  return true
end

local function appendEvent(id, seq, frame, sector, address, value)
  local file, err = io.open(outputPath, "ab")
  if file == nil then
    emu.log("TITLE GFX PROBE ERROR appending " .. outputPath .. ": " .. tostring(err))
    return false
  end

  file:write(string.format(
    "%s\t%d\t%d\t%d\t%04X\t%02X\n",
    id, seq, frame, sector, address, value
  ))

  file:flush()
  file:close()
  return true
end

local function onWrite(address, value)
  local frame, sector = getFrameAndSector()

  if frame - lastLoggedFrame < COOLDOWN_FRAMES then
    return
  end

  lastLoggedFrame = frame
  sequence = sequence + 1

  local id = string.format("TITLE_GFX_%04d", sequence)

  appendEvent(id, sequence, frame, sector, address, value)

  emu.log(string.format(
    "TITLE GFX LOAD[%d] id=%s frame=%d sector=%d addr=$%04X value=$%02X",
    sequence,
    id,
    frame,
    sector,
    address,
    value
  ))
end

if not ensureHeader() then
  return
end

-- Mesen callback for CPU memory writes.
-- Callback fires only for writes in $3B00-$3B1F.
emu.addMemoryCallback(
  function(address, value)
    onWrite(address, value)
  end,
  emu.callbackType.write,
  START_ADDR,
  END_ADDR
)

emu.log("PROBE_TITLE_GFX_SECTOR loaded")
emu.log(string.format(
  "Watching CPU writes $%04X-$%04X and logging cdrom.scsi.sector.",
  START_ADDR,
  END_ADDR
))
emu.log("Power-cycle and enter the title screen.")
emu.log("Output: " .. outputPath)
