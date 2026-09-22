-- Snatcher PCE-CD opening audio path probe for Mesen 2
-- Purpose:
--   Find audio state changes used by the opening narration when the normal
--   runtime_text_audit.lua ADPCM detector does not see them.
--
-- Usage:
--   1) Stop all other Lua scripts in Mesen.
--   2) Enable: Script -> Settings -> Script Window -> Restrictions -> Allow I/O and OS
--   3) Run this script.
--   4) Power-cycle and let the opening narration play.
--   5) Stop the script after the opening.
--
-- Output:
--   C:\snatcher\dump\opening_audio_probe_YYYYMMDD_HHMMSS.tsv
--
-- The TSV records every change of state keys related to:
--   cdrom / audio / adpcm / cdda / pcm / scsi / sound
-- Console output is intentionally much smaller than the TSV.

local function nowStamp()
  if os ~= nil and os.date ~= nil then
    return os.date("%Y%m%d_%H%M%S")
  end
  return "session"
end

local outputPath = "C:\\snatcher\\dump\\opening_audio_probe_" .. nowStamp() .. ".tsv"

local previous = {}
local initialized = false
local eventSequence = 0

local function currentFrame(state)
  if type(state) ~= "table" then return 0 end
  local v = state["frameCount"]
  if type(v) == "number" then return v end
  return 0
end

local function escape(value)
  if value == nil then return "<nil>" end
  local t = type(value)
  if t == "boolean" then
    return value and "true" or "false"
  elseif t == "number" then
    return tostring(value)
  elseif t == "string" then
    return value:gsub("\\", "\\\\"):gsub("\t", "\\t"):gsub("\r", "\\r"):gsub("\n", "\\n")
  else
    return "<" .. t .. ">"
  end
end

local function isScalar(value)
  local t = type(value)
  return t == "number" or t == "boolean" or t == "string" or value == nil
end

-- emu.getState() is usually a flat key/value table on PCE, but recursively
-- flatten nested tables too so the probe survives API/layout differences.
local function flattenTable(source, prefix, out, depth)
  if type(source) ~= "table" then return end
  if depth > 8 then return end

  for key, value in pairs(source) do
    local keyText = tostring(key)
    local fullKey = prefix == "" and keyText or (prefix .. "." .. keyText)

    if type(value) == "table" then
      flattenTable(value, fullKey, out, depth + 1)
    elseif isScalar(value) then
      out[fullKey] = value
    end
  end
end

local function interestingKey(key)
  local lower = string.lower(key)
  return string.find(lower, "cdrom", 1, true) ~= nil
      or string.find(lower, "audio", 1, true) ~= nil
      or string.find(lower, "adpcm", 1, true) ~= nil
      or string.find(lower, "cdda", 1, true) ~= nil
      or string.find(lower, "pcm", 1, true) ~= nil
      or string.find(lower, "scsi", 1, true) ~= nil
      or string.find(lower, "sound", 1, true) ~= nil
end

local function consoleWorthy(key, oldValue, newValue)
  local lower = string.lower(key)

  -- Always show boolean/string transitions.
  if type(oldValue) == "boolean" or type(newValue) == "boolean"
      or type(oldValue) == "string" or type(newValue) == "string" then
    return true
  end

  -- Show likely mode/playback/status fields, but avoid flooding the console
  -- with continuously advancing sector/address counters.
  return string.find(lower, "play", 1, true) ~= nil
      or string.find(lower, "status", 1, true) ~= nil
      or string.find(lower, "mode", 1, true) ~= nil
      or string.find(lower, "state", 1, true) ~= nil
      or string.find(lower, "command", 1, true) ~= nil
      or string.find(lower, "rate", 1, true) ~= nil
      or string.find(lower, "length", 1, true) ~= nil
end

local function ensureOutput()
  local file, err = io.open(outputPath, "wb")
  if file == nil then
    emu.log("OPENING AUDIO PROBE ERROR: " .. tostring(err))
    return false
  end

  file:write("seq\tframe\tkey\told_value\tnew_value\n")
  file:flush()
  file:close()
  return true
end

local function appendEvent(frame, key, oldValue, newValue)
  local file, err = io.open(outputPath, "ab")
  if file == nil then
    emu.log("OPENING AUDIO PROBE ERROR appending: " .. tostring(err))
    return false
  end

  eventSequence = eventSequence + 1
  file:write(string.format(
    "%d\t%d\t%s\t%s\t%s\n",
    eventSequence,
    frame,
    key,
    escape(oldValue),
    escape(newValue)
  ))
  file:flush()
  file:close()

  if consoleWorthy(key, oldValue, newValue) then
    emu.log(string.format(
      "OA[%d] frame=%d %s: %s -> %s",
      eventSequence,
      frame,
      key,
      escape(oldValue),
      escape(newValue)
    ))
  end

  return true
end

local function writeInitialInventory(frame, flat)
  local keys = {}
  for key, _ in pairs(flat) do
    if interestingKey(key) then
      keys[#keys + 1] = key
    end
  end
  table.sort(keys)

  local file, err = io.open(outputPath, "ab")
  if file == nil then
    emu.log("OPENING AUDIO PROBE ERROR inventory: " .. tostring(err))
    return
  end

  for _, key in ipairs(keys) do
    eventSequence = eventSequence + 1
    file:write(string.format(
      "%d\t%d\t%s\t%s\t%s\n",
      eventSequence,
      frame,
      key,
      "<baseline>",
      escape(flat[key])
    ))
  end

  file:flush()
  file:close()
  emu.log(string.format("OPENING AUDIO PROBE baseline keys=%d", #keys))
end

local function probeAtFrame()
  local ok, state = pcall(emu.getState)
  if not ok or type(state) ~= "table" then
    return
  end

  local flat = {}
  flattenTable(state, "", flat, 0)
  local frame = currentFrame(state)

  if not initialized then
    writeInitialInventory(frame, flat)
    for key, value in pairs(flat) do
      if interestingKey(key) then
        previous[key] = value
      end
    end
    initialized = true
    return
  end

  -- Detect changed/new keys.
  for key, newValue in pairs(flat) do
    if interestingKey(key) then
      local oldValue = previous[key]
      if oldValue == nil and newValue ~= nil then
        appendEvent(frame, key, "<missing>", newValue)
      elseif oldValue ~= newValue then
        appendEvent(frame, key, oldValue, newValue)
      end
      previous[key] = newValue
    end
  end

  -- Detect keys that disappeared from state.
  local disappeared = {}
  for key, oldValue in pairs(previous) do
    if interestingKey(key) and flat[key] == nil then
      disappeared[#disappeared + 1] = { key = key, oldValue = oldValue }
    end
  end

  for _, item in ipairs(disappeared) do
    appendEvent(frame, item.key, item.oldValue, "<missing>")
    previous[item.key] = nil
  end
end

if not ensureOutput() then
  return
end

emu.addEventCallback(probeAtFrame, emu.eventType.endFrame)

emu.log("PROBE_OPENING_AUDIO loaded")
emu.log("Power-cycle, play the opening narration, then stop the script.")
emu.log("TSV output: " .. outputPath)
