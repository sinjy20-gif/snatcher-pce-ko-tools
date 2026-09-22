-- SUB 0.4.25 -- common subtitle VRAM hole across portrait layouts / read-only.
--
-- Capture the same layouts as 0.4.24:
--   Q=L   W=C   E=R
--   A=LC  S=LR  D=CR  F=LCR
--   G=NONE, R=OTHER
--
-- Each capture marks the live BAT pattern words, every SATB sprite pattern
-- (including its decoded size), the BAT table, and SATB itself.  The reported
-- candidate list is the intersection: a 19-cell ($4C0-word) block unreferenced
-- by every captured layout so far.  No CPU/VRAM/AC writes are performed.

local VRAM = emu.memType.pceVideoRam
local stamp = os.date('%Y%m%d_%H%M%S')
local ROOT = 'C:/snatcher/dump/sub_0_4_25_common_vram_' .. stamp
local SUMMARY = ROOT .. '_summary.tsv'
local CANDIDATES = ROOT .. '_candidates.tsv'
local summaryFile = assert(io.open(SUMMARY, 'w'))
local candidateFile = assert(io.open(CANDIDATES, 'w'))

local VRAM_WORDS = 0x8000
local SATB_FIRST, SATB_WORDS = 0x1000, 0x0100
local NEED_WORDS = 19 * 0x40                 -- 19 subtitle cells = $4C0 words
local ALIGN = 0x40
local frame, captureSeq, closed = 0, 0, false
local held = { Q=false, W=false, E=false, A=false, S=false, D=false,
               F=false, G=false, R=false }
local unionUsed = {}

local function rb(at)
  return emu.read(at, VRAM) or 0
end

local function rw(wordAt)
  local at = wordAt * 2
  return rb(at) | (rb(at + 1) << 8)
end

local function keyDown(name)
  local ok, value = pcall(function() return emu.isKeyPressed(name) end)
  return ok and value == true
end

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

local function mark(used, first, count)
  if first < 0 then return end
  local last = math.min(VRAM_WORDS - 1, first + count - 1)
  for word = first, last do used[word] = true end
end

local function collectUsed()
  local used, patterns = {}, {}
  local columns, rows = dimensions()
  local batEntries = math.min(columns * rows, SATB_FIRST)

  -- The BAT table itself cannot hold sprite patterns.
  mark(used, 0, batEntries)
  for i = 0, batEntries - 1 do
    local pattern = rw(i) & 0x07FF
    if not patterns[pattern] then
      patterns[pattern] = true
      mark(used, pattern * 0x10, 0x10)        -- BG 8x8 4bpp = 16 words
    end
  end

  -- SATB storage and all sprite pattern extents.
  mark(used, SATB_FIRST, SATB_WORDS)
  local sprites = 0
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
      mark(used, (pattern & 0x07FF) << 5,
           widthCells * heightCells * 0x40)
      sprites = sprites + 1
    end
  end

  local bgPatterns = 0
  for _ in pairs(patterns) do bgPatterns = bgPatterns + 1 end
  return used, columns, rows, bgPatterns, sprites
end

local function mergeUnion(used)
  for word in pairs(used) do unionUsed[word] = true end
end

local function candidates(used)
  local out = {}
  for base = SATB_FIRST + SATB_WORDS, VRAM_WORDS - NEED_WORDS, ALIGN do
    local free = true
    for word = base, base + NEED_WORDS - 1 do
      if used[word] then free = false; break end
    end
    if free then out[#out + 1] = base end
  end
  return out
end

local function usedRanges(used)
  local ranges, first = {}, nil
  for word = 0, VRAM_WORDS do
    local on = word < VRAM_WORDS and used[word] == true
    if on and not first then first = word end
    if not on and first then
      ranges[#ranges + 1] = string.format('%04X-%04X', first, word - 1)
      first = nil
    end
  end
  return table.concat(ranges, ',')
end

summaryFile:write('case\tcapture\tframe\tbat_columns\tbat_rows\tbg_patterns\t' ..
  'satb_sprites\tcase_candidates\tcommon_candidates\tfirst_common\tused_ranges\n')
candidateFile:write('case\tcapture\tframe\tbase\tlast\twords\n')

local function capture(caseLabel)
  captureSeq = captureSeq + 1
  local used, columns, rows, bgPatterns, sprites = collectUsed()
  local caseCandidates = candidates(used)
  mergeUnion(used)
  local common = candidates(unionUsed)
  local first = (#common > 0) and string.format('%04X-%04X', common[1],
                                                common[1] + NEED_WORDS - 1) or ''
  summaryFile:write(string.format(
    '%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%s\n',
    caseLabel, captureSeq, frame, columns, rows, bgPatterns, sprites,
    #caseCandidates, #common, first, usedRanges(used)))
  for _, base in ipairs(common) do
    candidateFile:write(string.format('%s\t%d\t%d\t%04X\t%04X\t%d\n',
      caseLabel, captureSeq, frame, base, base + NEED_WORDS - 1, NEED_WORDS))
  end
  summaryFile:flush(); candidateFile:flush()

  local preview = {}
  for i = 1, math.min(6, #common) do
    preview[#preview + 1] = string.format('$%04X', common[i])
  end
  emu.log(string.format(
    'SUB 0.4.25 ★ %s: BAT=%dx%d/%d patterns SATB=%d · common holes=%d [%s]',
    caseLabel, columns, rows, bgPatterns, sprites, #common,
    table.concat(preview, ' ')))
end

emu.addEventCallback(function()
  frame = frame + 1
  local map = {
    Q='L', W='C', E='R', A='LC', S='LR', D='CR', F='LCR',
    G='NONE', R='OTHER'
  }
  for key, caseLabel in pairs(map) do
    local down = keyDown(key)
    if down and not held[key] then capture(caseLabel) end
    held[key] = down
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if closed then return end
  closed = true
  summaryFile:close(); candidateFile:close()
  emu.log('SUB 0.4.25 saved: ' .. SUMMARY)
  emu.log('SUB 0.4.25 saved: ' .. CANDIDATES)
end, emu.eventType.scriptEnded)

emu.log('SUB 0.4.25 loaded -- common BAT+SATB VRAM hole / read-only')
emu.log('  Q=L W=C E=R · A=LC S=LR D=CR · F=LCR · G=NONE · R=OTHER')
emu.log('  need: 19 x $40 = $4C0 VRAM words')
emu.log('  output: ' .. SUMMARY)
