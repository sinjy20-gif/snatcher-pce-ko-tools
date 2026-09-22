-- SUB 0.2.5 -- read-only VRAM safety survey for subtitle collection.
-- Load alongside normal runtime collection. It never enables/draws subtitles.
-- For every ADPCM voice it records candidate 19-glyph blocks that were blank
-- and SATB-free at start, and whether the game touched them before voice end.

local MEM, VRAM, CPU = emu.memType.pceMemory, emu.memType.pceVideoRam, emu.memType.cpu
local OUT = 'C:/snatcher/snatcher_tool/logs/subtitle_vram_survey_v025.tsv'
local WORDS = 19 * 0x40
local seq, active = 0, nil
local vdcReg, mawrLo, mawr = 0, 0, 0

local function number(s, key)
  local v = s[key]; return type(v) == 'number' and math.floor(v) or 0
end
local function rb(a) return emu.read(a, VRAM) or 0 end
local function satbUses(base)
  local lo = (base >> 5) & 0xFFFF
  for slot = 0, 63 do
    local at = 0x2000 + slot * 8 + 4
    local pat = rb(at) | (rb(at + 1) << 8)
    if pat >= lo and pat < lo + 38 then return true end
  end
  return false
end
local function blank(base)
  for word = base, base + WORDS - 1 do
    local at = word * 2
    if rb(at) ~= 0 or rb(at + 1) ~= 0 then return false end
  end
  return true
end
local function keyOf(s)
  local sector = number(s, 'cdrom.scsi.sector')
  local ending = (number(s, 'cdrom.adpcm.readAddress') + number(s, 'cdrom.adpcm.adpcmLength')) % 0x10000
  local rate = number(s, 'cdrom.adpcm.playbackRate')
  return string.format('ADPCM_%06X_%04X_%02X', sector, ending, rate), sector, ending, rate
end
local function ensureHeader()
  local f = io.open(OUT, 'rb'); local empty = f == nil
  if f then empty = (f:seek('end') or 0) == 0; f:close() end
  if not empty then return end
  f = assert(io.open(OUT, 'ab'))
  f:write('event_id\tframe_start\tframe_end\tkey\tsector\tend_address\trate\tduration_frames\tstart_safe_blocks\ttouched_start_safe\tend_safe_blocks\tstatus\n')
  f:close()
end
local function join(t) return #t == 0 and '-' or table.concat(t, ',') end
local function finish(frame, status)
  if not active then return end
  local startSafe, touched, endSafe = {}, {}, {}
  for _, c in ipairs(active.candidates) do
    if c.safe then
      startSafe[#startSafe + 1] = string.format('%04X', c.base)
      if c.writes > 0 then touched[#touched + 1] = string.format('%04X:%d', c.base, c.writes) end
      if c.writes == 0 and blank(c.base) and not satbUses(c.base) then endSafe[#endSafe + 1] = string.format('%04X', c.base) end
    end
  end
  local f = assert(io.open(OUT, 'ab'))
  f:write(string.format('%s\t%d\t%d\t%s\t%06X\t%04X\t%02X\t%d\t%s\t%s\t%s\t%s\n',
    active.id, active.start, frame, active.key, active.sector, active.ending, active.rate,
    math.max(0, frame - active.start), join(startSafe), join(touched), join(endSafe), status))
  f:close()
  emu.log(string.format('SUB 0.2.5 END %s safe=%s touched=%s', active.key, join(endSafe), join(touched)))
  active = nil
end
local function begin(s, frame)
  if active then finish(frame, 'interrupted') end
  seq = seq + 1
  local key, sector, ending, rate = keyOf(s)
  local candidates = {}
  for base = 0x6000, 0x7B00, 0x100 do
    candidates[#candidates + 1] = {base = base, safe = blank(base) and not satbUses(base), writes = 0}
  end
  active = {id = string.format('v025_%06d', seq), start = frame, key = key,
    sector = sector, ending = ending, rate = rate, candidates = candidates}
  local starts = {}
  for _, c in ipairs(candidates) do if c.safe then starts[#starts + 1] = string.format('%04X', c.base) end end
  emu.log(string.format('SUB 0.2.5 START %s start-safe=%s', key, join(starts)))
end

-- Read VDC MAWR / VWR traffic; no callback writes are performed.
emu.addMemoryCallback(function(address, value)
  if address == 0 then
    vdcReg = value or 0
  elseif address == 2 and vdcReg == 0 then
    mawrLo = value or 0
  elseif address == 3 and vdcReg == 0 then
    mawr = mawrLo | ((value or 0) << 8)
  elseif address == 3 and vdcReg == 2 then
    if active then
      for _, c in ipairs(active.candidates) do
        if c.safe and mawr >= c.base and mawr < c.base + WORDS then c.writes = c.writes + 1 end
      end
    end
    mawr = (mawr + 1) & 0xFFFF
  end
end, emu.callbackType.write, 0x0000, 0x0003, emu.cpuType.pce, CPU)

ensureHeader()
emu.addEventCallback(function()
  local s = emu.getState() or {}; local frame = number(s, 'frameCount')
  local playing = s['cdrom.adpcm.playing'] == true
  if playing and not active then begin(s, frame)
  elseif not playing and active then finish(frame, 'complete') end
end, emu.eventType.endFrame)
emu.addEventCallback(function()
  local s = emu.getState() or {}; if active then finish(number(s, 'frameCount'), 'script_stopped') end
end, emu.eventType.scriptEnded)

emu.log('SUB 0.2.5 loaded -- read-only VRAM survey / subtitle draw·CPU·AC·VRAM writes 0 B')
emu.log('  output: ' .. OUT)
