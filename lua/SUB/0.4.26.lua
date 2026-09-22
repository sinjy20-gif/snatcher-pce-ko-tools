-- SUB 0.4.26 -- candidate $1600-$1ABF lifetime watcher / read-only.
--
-- 0.4.25 found this 19-cell ($4C0-word) window unreferenced in all eight
-- portrait layouts: NONE/L/C/R/LC/LR/CR/LCR.  A still capture is not enough:
-- the game may upload to or reference the window later.  This probe watches
-- both for the lifetime of the relevant scene.
--
-- It performs no CPU/VRAM/AC writes.
-- Start before entering the portrait sequence, play through every appearance
-- and transition that matters, then stop the script.  PASS requires zero
-- target writes and zero BAT/SATB references for the whole run.

local VRAM = emu.memType.pceVideoRam
local FIRST_WORD, LAST_WORD = 0x1600, 0x1ABF
local FIRST_BYTE, LAST_BYTE = FIRST_WORD * 2, LAST_WORD * 2 + 1
local NEED_WORDS = LAST_WORD - FIRST_WORD + 1
local SATB_FIRST, SATB_WORDS = 0x1000, 0x0100
local REF_SCAN_EVERY = 10

local stamp = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/sub_0_4_26_vram_lifetime_' .. stamp .. '.tsv'
local file = assert(io.open(OUT, 'w'))
file:write('frame\tevent\tcallback_writes\tunique_words\tfirst_word\tlast_word\t' ..
           'bat_refs\tsatb_refs\tdetail\n')

local frame, closed = 0, false
local callbackWrites, writeFrames, totalUniqueWrites = 0, 0, 0
local everWritten = {}
local pending = {}
local pendingCount, pendingFirst, pendingLast = 0, nil, nil
local refScans, batRefFrames, satbRefFrames = 0, 0, 0
local lastBatRefs, lastSatbRefs = 0, 0
local maxBatRefs, maxSatbRefs = 0, 0
local callbackInstalled = false

local function rb(at)
  return emu.read(at, VRAM) or 0
end

local function rw(wordAt)
  local at = wordAt * 2
  return rb(at) | (rb(at + 1) << 8)
end

local function overlaps(first, count)
  local last = first + count - 1
  return first <= LAST_WORD and last >= FIRST_WORD
end

-- pceVideoRam addresses are bytes.  Coalesce every callback in one frame so a
-- DMA-sized upload cannot flood the console or TSV with thousands of lines.
local function onWrite(address)
  local word = math.floor(address / 2)
  if word < FIRST_WORD or word > LAST_WORD then return end
  callbackWrites = callbackWrites + 1
  if not pending[word] then
    pending[word] = true
    pendingCount = pendingCount + 1
    pendingFirst = pendingFirst and math.min(pendingFirst, word) or word
    pendingLast = pendingLast and math.max(pendingLast, word) or word
  end
  if not everWritten[word] then
    everWritten[word] = true
    totalUniqueWrites = totalUniqueWrites + 1
  end
end

callbackInstalled = pcall(function()
  emu.addMemoryCallback(onWrite, emu.callbackType.write,
                        FIRST_BYTE, LAST_BYTE, nil, VRAM)
end)

local function saneDimension(value, fallback)
  value = tonumber(value)
  if value == 32 or value == 64 or value == 128 then return value end
  return fallback
end

local function dimensions()
  local ok, state = pcall(emu.getState)
  if not ok or not state then return 64, 64 end
  return saneDimension(state['vdc.hvReg.columnCount'], 64),
         saneDimension(state['vdc.hvReg.rowCount'], 64)
end

local function references()
  local batRefs, satbRefs, details = 0, 0, {}
  local columns, rows = dimensions()
  local batEntries = math.min(columns * rows, SATB_FIRST)

  for i = 0, batEntries - 1 do
    local pattern = rw(i) & 0x07FF
    local base = pattern * 0x10
    if overlaps(base, 0x10) then
      batRefs = batRefs + 1
      if #details < 12 then
        details[#details + 1] = string.format('BAT[%04X]->%04X', i, base)
      end
    end
  end

  for slot = 0, 63 do
    local at = 0x2000 + slot * 8
    local y = rb(at) | (rb(at + 1) << 8)
    local x = rb(at + 2) | (rb(at + 3) << 8)
    local pattern = rb(at + 4) | (rb(at + 5) << 8)
    local attr = rb(at + 6) | (rb(at + 7) << 8)
    if y ~= 0 or x ~= 0 or pattern ~= 0 or attr ~= 0 then
      local widthCells = ((attr & 0x0100) ~= 0) and 2 or 1
      local hcode = (attr >> 12) & 0x03
      local heightCells = (hcode == 0) and 1 or ((hcode == 1) and 2 or 4)
      local base = (pattern & 0x07FF) << 5
      local words = widthCells * heightCells * 0x40
      if overlaps(base, words) then
        satbRefs = satbRefs + 1
        if #details < 12 then
          details[#details + 1] = string.format(
            'SATB[%02d]->%04X-%04X', slot, base, base + words - 1)
        end
      end
    end
  end
  return batRefs, satbRefs, table.concat(details, ',')
end

local function logRow(event, writes, unique, first, last, bat, satb, detail)
  file:write(string.format('%d\t%s\t%d\t%d\t%s\t%s\t%d\t%d\t%s\n',
    frame, event, writes or 0, unique or 0,
    first and string.format('%04X', first) or '',
    last and string.format('%04X', last) or '',
    bat or 0, satb or 0, detail or ''))
  file:flush()
end

emu.addEventCallback(function()
  frame = frame + 1

  if pendingCount > 0 then
    writeFrames = writeFrames + 1
    logRow('WRITE', callbackWrites, pendingCount, pendingFirst, pendingLast,
           lastBatRefs, lastSatbRefs, '')
    emu.log(string.format(
      'SUB 0.4.26 ★ TARGET WRITE f=%d unique=%d span=$%04X-$%04X total_callbacks=%d',
      frame, pendingCount, pendingFirst, pendingLast, callbackWrites))
    pending, pendingCount, pendingFirst, pendingLast = {}, 0, nil, nil
  end

  if frame == 1 or frame % REF_SCAN_EVERY == 0 then
    refScans = refScans + 1
    local bat, satb, detail = references()
    if bat > 0 then batRefFrames = batRefFrames + 1 end
    if satb > 0 then satbRefFrames = satbRefFrames + 1 end
    maxBatRefs, maxSatbRefs = math.max(maxBatRefs, bat), math.max(maxSatbRefs, satb)
    if bat ~= lastBatRefs or satb ~= lastSatbRefs then
      local event = (bat > 0 or satb > 0) and 'REF_CHANGE_COLLISION' or 'REF_CLEAR'
      logRow(event, 0, 0, nil, nil, bat, satb, detail)
      if bat > 0 or satb > 0 then
        emu.log(string.format(
          'SUB 0.4.26 ★ TARGET REFERENCED f=%d BAT=%d SATB=%d %s',
          frame, bat, satb, detail))
      else
        emu.log(string.format('SUB 0.4.26 target references cleared f=%d', frame))
      end
    end
    lastBatRefs, lastSatbRefs = bat, satb
  end

  local bad = callbackWrites > 0 or maxBatRefs > 0 or maxSatbRefs > 0
  local text = string.format('0.4.26 $1600 WATCH  W:%d B:%d S:%d',
                             callbackWrites, maxBatRefs, maxSatbRefs)
  emu.drawString(4, 4, text, bad and 0xFF4040 or 0x40FF40, 0x000000)
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if closed then return end
  closed = true
  local pass = callbackInstalled and callbackWrites == 0 and
               maxBatRefs == 0 and maxSatbRefs == 0
  logRow(pass and 'SUMMARY_PASS' or 'SUMMARY_FAIL', callbackWrites,
         totalUniqueWrites, FIRST_WORD, LAST_WORD, maxBatRefs, maxSatbRefs,
         string.format('frames=%d;write_frames=%d;ref_scans=%d;bat_ref_scans=%d;' ..
                       'satb_ref_scans=%d;callback_installed=%d',
                       frame, writeFrames, refScans, batRefFrames, satbRefFrames,
                       callbackInstalled and 1 or 0))
  file:close()
  emu.log(string.format(
    'SUB 0.4.26 ★ %s: frames=%d writes=%d unique_words=%d maxBAT=%d maxSATB=%d',
    pass and 'PASS' or 'FAIL', frame, callbackWrites, totalUniqueWrites,
    maxBatRefs, maxSatbRefs))
  emu.log('SUB 0.4.26 saved: ' .. OUT)
end, emu.eventType.scriptEnded)

emu.log('SUB 0.4.26 loaded -- $1600-$1ABF lifetime write/reference audit')
emu.log(string.format('  target: $%04X-$%04X (%d words / 19 cells)',
                      FIRST_WORD, LAST_WORD, NEED_WORDS))
emu.log('  read-only · enter before portrait sequence, play through transitions, then Stop')
emu.log('  callback installed: ' .. tostring(callbackInstalled))
emu.log('  output: ' .. OUT)

