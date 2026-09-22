-- SUB 0.4.27 -- one known subtitle on every ADPCM, fixed VRAM $1600.
--
-- Destructive only to the subtitle experiment state: it deliberately makes
-- every real rate-$0E ADPCM look like the already-proven E6800_0E subtitle at
-- the native $FEC4 gate.  Audio playback and game code are not skipped.
-- The dynamic renderer/helper operands are moved to the 0.4.25/0.4.26
-- candidate window $1600-$1ABF.
--
-- Run this only AFTER stopping 0.4.26 and confirming SUMMARY_PASS.  Do not run
-- both together: 0.4.27 intentionally writes glyphs to the watched window.

local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce
local STATE = 0x7FDF
local GATE = 0xFEC4
local TARGET_END, TARGET_RATE = 0x6800, 0x0E

local forced, held, lastPlaying = 0, nil, nil

local function number(state, key)
  local value = state[key]
  return type(value) == 'number' and value or 0
end

local function actualVoice()
  local ok, state = pcall(emu.getState)
  if not ok or not state or state['cdrom.adpcm.playing'] ~= true then return nil end
  local read = number(state, 'cdrom.adpcm.readAddress')
  local length = number(state, 'cdrom.adpcm.adpcmLength')
  local finish = (read + length) & 0xFFFF
  local rate = number(state, 'cdrom.adpcm.playbackRate')
  local sector = number(state, 'cdrom.scsi.sector')
  return {
    finish = finish, rate = rate,
    id = string.format('%06X_%04X_%02X', sector, finish, rate)
  }
end

-- $FEC4 is the native subtitle gate.  Force its three measured fingerprint
-- bytes only once per real playback.  Build 0.4.6.11 consumes $22A7 after
-- accepting it, preventing the old repeated false-start loop.
emu.addMemoryCallback(function()
  if (emu.read(STATE, MEM) or 0) ~= 0 then return end
  local voice = actualVoice()
  if not voice or voice.rate ~= TARGET_RATE or held == voice.id then return end

  emu.write(0x22A6, TARGET_END & 0xFF, MEM)
  emu.write(0x22A7, TARGET_END >> 8, MEM)
  emu.write(0x22AA, TARGET_RATE, MEM)
  held, lastPlaying = voice.id, voice.id
  forced = forced + 1
  emu.log(string.format(
    'SUB 0.4.27 ★ ALLVOICE #%d actual=%s -> dummy E6800_0E', forced, voice.id))
end, emu.callbackType.exec, GATE, GATE, CPU, MEM)

emu.addEventCallback(function()
  local voice = actualVoice()
  if not voice then
    held, lastPlaying = nil, nil
  elseif lastPlaying and voice.id ~= lastPlaying then
    held = nil
    lastPlaying = voice.id
  else
    lastPlaying = voice.id
  end

  emu.drawString(4, 4,
    string.format('0.4.27 ALLVOICE $1600  N:%d', forced),
    0x40FF40, 0x000000)
end, emu.eventType.endFrame)

-- Reuse the measured renderer patch chain.  `false` is the explicit all-ADPCM
-- mode added for this wrapper; FORCE_BASE keeps every fragment at $1600.
SUB_ALLOCATOR_VERSION = '0.4.27-allvoice-1600'
SUB_ALLOCATOR_INPLACE_IMAGES = true
SUB_ALLOCATOR_TARGET_END = false
SUB_ALLOCATOR_FORCE_BASE = 0x1600
SUB_ALLOCATOR_PATCH_AT_COUNT_OK = true
dofile('C:/snatcher/lua/SUB/0.3.42-wide.lua')
SUB_ALLOCATOR_VERSION = nil
SUB_ALLOCATOR_INPLACE_IMAGES = nil
SUB_ALLOCATOR_TARGET_END = nil
SUB_ALLOCATOR_FORCE_BASE = nil
SUB_ALLOCATOR_PATCH_AT_COUNT_OK = nil

emu.log('SUB 0.4.27 loaded -- every rate-$0E ADPCM uses one dummy subtitle')
emu.log('  fixed candidate VRAM $1600-$1ABF · no disc build')
emu.log('  prerequisite: 0.4.26 SUMMARY_PASS; do not run both scripts together')

