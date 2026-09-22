-- CD-DA Track 4 VRAM collision probe 0.1 -- read-only
--
-- Why this exists
-- ---------------
-- The previous CD-DA map treats a range as free when no BAT/SATB reference
-- survives its observation.  Track 4 nevertheless corrupts graphics with
-- the shipping subtitle base $6B00.  That can be an ordering collision: the
-- game writes or references the range only briefly in the same frame as the
-- subtitle renderer.  A clip-level free-span map cannot prove that safe.
--
-- This probe reconstructs VDC writes from ports $0000-$0003, exactly as the
-- validated VDC watcher does, but limits itself to the active Track 4 range.
-- It records the writing PC, current CD LBA, and the frame-end BAT/SATB
-- references.  It never writes emulator memory or VDC state.
--
-- Use one script only.  Run the current build through Track 4, then stop the
-- script.  Output: dump/cdda_track4_vram_collision_<timestamp>.tsv

local VERSION = '0.1'
local MEM = emu.memType.pceMemory
local VRAM = emu.memType.pceVideoRam
local CPU = emu.cpuType.pce

-- Current shipping Track 4 subtitle block: 19 glyphs * $40 words.
local FIRST_WORD, LAST_WORD = 0x6B00, 0x6FBF
local TRACK4_FIRST_LBA, TRACK4_LAST_LBA = 43362, 54106

local stamp = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/cdda_track4_vram_collision_' .. stamp .. '.tsv'
local out = assert(io.open(OUT, 'w'))
out:write('frame\tlba\tevent\twriter\tpc\tfirst\tlast\twords\tbat_refs\tsatb_refs\tdetail\n')

local frame, rows, closed = 0, 0, false
local reg, mawr = 0, 0
local dataLo = 0
local pending = {}

local function state()
  local ok, s = pcall(emu.getState)
  return ok and s or {}
end

local function lba()
  local n = state()['cdrom.audioPlayer.currentSector']
  return type(n) == 'number' and math.floor(n) or -1
end

local function inTrack4()
  local n = lba()
  return n >= TRACK4_FIRST_LBA and n <= TRACK4_LAST_LBA
end

local function who(pc)
  -- Current 0.7.6-gapfix renderer/cache/scheduler plus the RAM slot used by
  -- older images.  Everything else is the game; this classification is only
  -- for the log and changes no execution.
  if (pc >= 0x5B80 and pc <= 0x5FFF)
      or (pc >= 0xECF9 and pc <= 0xF0FF)
      or (pc >= 0xFD00 and pc <= 0xFFFF) then
    return 'subtitle'
  end
  return 'game'
end

local function rb(addr)
  return emu.read(addr, VRAM) or 0
end

local function rw(word)
  local at = word * 2
  return rb(at) | (rb(at + 1) << 8)
end

local function overlap(first, words)
  return first <= LAST_WORD and first + words - 1 >= FIRST_WORD
end

local function log(event, writer, pc, first, last, words, bat, satb, detail)
  out:write(string.format('%d\t%d\t%s\t%s\t%04X\t%s\t%s\t%d\t%d\t%d\t%s\n',
    frame, lba(), event, writer or '', pc or 0,
    first and string.format('%04X', first) or '',
    last and string.format('%04X', last) or '', words or 0, bat or 0, satb or 0,
    detail or ''))
  out:flush()
  rows = rows + 1
end

local function noteWrite(word)
  if not inTrack4() or word < FIRST_WORD or word > LAST_WORD then return end
  local pc = state()['cpu.pc'] or 0
  local key = who(pc) .. '|' .. pc
  local row = pending[key]
  if not row then
    row = { first = word, last = word, words = 0, pc = pc, writer = who(pc) }
    pending[key] = row
  end
  row.first = math.min(row.first, word)
  row.last = math.max(row.last, word)
  row.words = row.words + 1
end

local function onVdcWrite(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF
  if port == 0 then
    reg = value
  elseif port == 2 then
    dataLo = value
    if reg == 0x00 then
      mawr = (mawr & 0xFF00) | value
    end
  elseif port == 3 then
    if reg == 0x00 then
      mawr = (mawr & 0x00FF) | (value << 8)
    elseif reg == 0x02 then
      noteWrite(mawr)
      mawr = (mawr + 1) & 0xFFFF
    end
  end
end

local installed = pcall(function()
  emu.addMemoryCallback(onVdcWrite, emu.callbackType.write,
                        0x0000, 0x03FF, CPU, MEM)
end)

local function scanReferences()
  local bat, satb = 0, 0
  local detail = {}
  local s = state()
  local cols = tonumber(s['vdc.hvReg.columnCount']) or 64
  local rowsN = tonumber(s['vdc.hvReg.rowCount']) or 64
  if cols ~= 32 and cols ~= 64 and cols ~= 128 then cols = 64 end
  if rowsN ~= 32 and rowsN ~= 64 then rowsN = 64 end

  for slot = 0, 63 do
    local at = 0x2000 + slot * 8
    local pattern = rb(at + 4) | (rb(at + 5) << 8)
    local attr = rb(at + 6) | (rb(at + 7) << 8)
    local width = (attr & 0x0100) ~= 0 and 2 or 1
    local h = (attr >> 12) & 3
    local height = h == 0 and 1 or (h == 1 and 2 or 4)
    local base = (pattern & 0x07FF) << 5
    local words = width * height * 0x40
    if overlap(base, words) then
      satb = satb + 1
      if #detail < 8 then
        detail[#detail + 1] = string.format('SATB[%02d]=%04X-%04X',
          slot, base, base + words - 1)
      end
    end
  end

  for i = 0, math.min(cols * rowsN, 0x1000) - 1 do
    local base = (rw(i) & 0x07FF) * 0x10
    if overlap(base, 0x10) then bat = bat + 1 end
  end
  return bat, satb, table.concat(detail, ';')
end

emu.addEventCallback(function()
  frame = frame + 1
  if not inTrack4() then return end

  for _, row in pairs(pending) do
    log('VDC_WRITE', row.writer, row.pc, row.first, row.last, row.words, 0, 0, '')
  end
  pending = {}

  local bat, satb, detail = scanReferences()
  if bat > 0 or satb > 0 then
    log('FRAME_REF', '', 0, nil, nil, 0, bat, satb, detail)
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if closed then return end
  closed = true
  out:write(string.format('# version=%s frames=%d rows=%d target=$%04X-$%04X installed=%s\n',
    VERSION, frame, rows, FIRST_WORD, LAST_WORD, tostring(installed)))
  out:close()
  emu.log(string.format('CDDA Track4 VRAM collision probe saved: %s (%d rows)', OUT, rows))
end, emu.eventType.scriptEnded)

emu.log(string.format('CDDA Track4 VRAM collision probe %s -- target $%04X-$%04X',
  VERSION, FIRST_WORD, LAST_WORD))
emu.log('  read-only · run this script alone through Track 4')
emu.log('  output: ' .. OUT)
