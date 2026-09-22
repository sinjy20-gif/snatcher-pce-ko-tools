-- Snatcher PCE-CD opening CD audio detector for Mesen 2
-- Lightweight version: watches only cdrom.audioPlayer.currentSector
--
-- Usage:
--   1) Stop other Lua scripts.
--   2) Run this script.
--   3) Power-cycle and play the opening.
--   4) Stop after the opening narration.
--
-- Output:
--   C:\snatcher\dump\opening_cd_audio_events.tsv
--
-- Detection:
--   START = currentSector begins advancing
--   END   = sector has not advanced for STOP_GRACE_FRAMES frames
--
-- Notes:
--   A short grace period avoids splitting one continuous CD-audio segment
--   because of tiny pauses/jitter between sector updates.

local outputPath = "C:\\snatcher\\dump\\opening_cd_audio_events.tsv"

-- 12 frames ~= 0.2 sec at 60 fps.
-- Increase if one narration segment gets split into several events.
local STOP_GRACE_FRAMES = 12

local wasActive = false
local active = nil
local sequence = 0

local previousSector = nil
local lastAdvanceFrame = nil

local function stateNumber(state, key)
  local value = state[key]
  if type(value) == "number" then return value end
  return 0
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
    emu.log("CD AUDIO ERROR opening " .. outputPath .. ": " .. tostring(err))
    return false
  end

  file:write("event_type\tevent_id\tsequence\tframe\tstart_sector\tend_sector\tduration_frames\tduration_seconds\n")
  file:flush()
  file:close()
  return true
end

local function appendEvent(kind, item, frame, endSector)
  local file, err = io.open(outputPath, "ab")
  if file == nil then
    emu.log("CD AUDIO ERROR appending " .. outputPath .. ": " .. tostring(err))
    return false
  end

  local durationFrames = 0
  local durationSeconds = 0.0

  if kind == "END" then
    durationFrames = frame - item.startFrame
    durationSeconds = durationFrames / 60.0
  end

  file:write(string.format(
    "%s\t%s\t%d\t%d\t%d\t%d\t%d\t%.3f\n",
    kind,
    item.id,
    item.sequence,
    frame,
    item.startSector,
    endSector or item.lastSector or item.startSector,
    durationFrames,
    durationSeconds
  ))

  file:flush()
  file:close()
  return true
end

local function startEvent(frame, sector)
  sequence = sequence + 1

  active = {
    id = string.format("CDDA_%04d", sequence),
    sequence = sequence,
    startFrame = frame,
    startSector = sector,
    lastSector = sector,
  }

  wasActive = true
  lastAdvanceFrame = frame

  appendEvent("START", active, frame, sector)

  emu.log(string.format(
    "CD AUDIO START[%d] id=%s frame=%d sector=%d",
    active.sequence,
    active.id,
    frame,
    sector
  ))
end

local function endEvent(frame)
  if not wasActive or active == nil then return end

  local endSector = active.lastSector
  local durationFrames = frame - active.startFrame

  appendEvent("END", active, frame, endSector)

  emu.log(string.format(
    "CD AUDIO END[%d] id=%s frame=%d sector=%d duration=%.3fs",
    active.sequence,
    active.id,
    frame,
    endSector,
    durationFrames / 60.0
  ))

  wasActive = false
  active = nil
  lastAdvanceFrame = nil
end

local function auditCdAudioAtFrame()
  local ok, state = pcall(emu.getState)
  if not ok or type(state) ~= "table" then return end

  local frame = stateNumber(state, "frameCount")
  local sector = state["cdrom.audioPlayer.currentSector"]

  if type(sector) ~= "number" then
    previousSector = nil
    if wasActive and lastAdvanceFrame ~= nil
        and frame - lastAdvanceFrame >= STOP_GRACE_FRAMES then
      endEvent(frame)
    end
    return
  end

  if previousSector == nil then
    previousSector = sector
    return
  end

  if sector ~= previousSector then
    if not wasActive then
      startEvent(frame, sector)
    else
      active.lastSector = sector
      lastAdvanceFrame = frame
    end
  elseif wasActive and lastAdvanceFrame ~= nil
      and frame - lastAdvanceFrame >= STOP_GRACE_FRAMES then
    endEvent(frame)
  end

  previousSector = sector
end

if not ensureHeader() then
  return
end

emu.addEventCallback(auditCdAudioAtFrame, emu.eventType.endFrame)

emu.log("PROBE_OPENING_CD_AUDIO loaded")
emu.log("Watching cdrom.audioPlayer.currentSector only.")
emu.log("Power-cycle and play the opening narration.")
emu.log("Output: " .. outputPath)
