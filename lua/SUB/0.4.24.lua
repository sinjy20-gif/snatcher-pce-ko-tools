-- SUB 0.4.24 -- portrait L/C/R occupancy capture / read-only.
--
-- Stable portrait screen, game window focused:
--   Q=L   W=C   E=R
--   A=LC  S=LR  D=CR  F=LCR
--   G=NONE, R=OTHER/unknown arrangement
-- Each press captures the current 64-entry SATB and groups touching visible
-- game sprites into screen-space components.  It never writes CPU/VRAM/AC.

local VRAM = emu.memType.pceVideoRam
local MEM = emu.memType.pceMemory
local stamp = os.date('%Y%m%d_%H%M%S')
local ROOT = 'C:/snatcher/dump/sub_0_4_24_portrait_mask_' .. stamp
local SLOTS_OUT = ROOT .. '_slots.tsv'
local GROUPS_OUT = ROOT .. '_groups.tsv'
local slotsFile = assert(io.open(SLOTS_OUT, 'w'))
local groupsFile = assert(io.open(GROUPS_OUT, 'w'))
local frame, captureSeq, closed = 0, 0, false
local held = { Q=false, W=false, E=false, A=false, S=false, D=false,
               F=false, G=false, R=false }

local function rb(at, kind)
  return emu.read(at, kind) or 0
end

local function word(at)
  return rb(at, VRAM) | (rb(at + 1, VRAM) << 8)
end

local function keyDown(name)
  local ok, value = pcall(function() return emu.isKeyPressed(name) end)
  return ok and value == true
end

local function sprite(slot)
  local at = 0x2000 + slot * 8
  local yWord, xWord = word(at), word(at + 2)
  local pattern, attr = word(at + 4), word(at + 6)
  local rawY, rawX = yWord & 0x03FF, xWord & 0x03FF
  local x, y = rawX - 32, rawY - 64
  local width = ((attr & 0x0100) ~= 0) and 32 or 16
  local hcode = (attr >> 12) & 0x03
  local height = (hcode == 0) and 16 or ((hcode == 1) and 32 or 64)
  local active = yWord ~= 0 or xWord ~= 0 or pattern ~= 0 or attr ~= 0
  local visible = active and x < 256 and y < 224 and x + width > 0 and y + height > 0
  local palette = attr & 0x0F
  -- Current renderer uses palette 15, 16x16 cells, and y=122.  This is only
  -- a classification hint; raw entries are always retained for comparison.
  local subtitleHint = visible and palette == 15 and width == 16 and height == 16
    and y >= 118 and y <= 126
  local bytes = {}
  for i = 0, 7 do bytes[#bytes + 1] = string.format('%02X', rb(at + i, VRAM)) end
  return {
    slot = slot, active = active, visible = visible, subtitle = subtitleHint,
    rawX = rawX, rawY = rawY, x = x, y = y, width = width, height = height,
    pattern = pattern, patternBase = (pattern & 0x07FF) << 5, attr = attr,
    palette = palette, priority = ((attr & 0x0080) ~= 0) and 1 or 0,
    hflip = ((attr & 0x0800) ~= 0) and 1 or 0,
    vflip = ((attr & 0x8000) ~= 0) and 1 or 0,
    raw = table.concat(bytes, ' '),
  }
end

local function touches(a, b)
  -- A one-pixel allowance joins tiled portrait pieces while keeping separated
  -- portraits as distinct components.
  return a.x <= b.x + b.width + 1 and b.x <= a.x + a.width + 1
     and a.y <= b.y + b.height + 1 and b.y <= a.y + a.height + 1
end

local function components(items)
  local parent = {}
  for i = 1, #items do parent[i] = i end
  local function find(i)
    while parent[i] ~= i do
      parent[i] = parent[parent[i]]
      i = parent[i]
    end
    return i
  end
  local function union(a, b)
    a, b = find(a), find(b)
    if a ~= b then parent[b] = a end
  end
  for i = 1, #items do
    for j = i + 1, #items do
      if touches(items[i], items[j]) then union(i, j) end
    end
  end
  local byRoot = {}
  for i, item in ipairs(items) do
    local root = find(i)
    local g = byRoot[root]
    if not g then
      g = { x0 = item.x, y0 = item.y, x1 = item.x + item.width - 1,
            y1 = item.y + item.height - 1, slots = {}, patterns = {} }
      byRoot[root] = g
    end
    g.x0, g.y0 = math.min(g.x0, item.x), math.min(g.y0, item.y)
    g.x1, g.y1 = math.max(g.x1, item.x + item.width - 1),
                   math.max(g.y1, item.y + item.height - 1)
    g.slots[#g.slots + 1] = string.format('%02d', item.slot)
    g.patterns[#g.patterns + 1] = string.format('%04X', item.patternBase)
  end
  local out = {}
  for _, g in pairs(byRoot) do out[#out + 1] = g end
  table.sort(out, function(a, b)
    if a.y0 ~= b.y0 then return a.y0 < b.y0 end
    return a.x0 < b.x0
  end)
  return out
end

slotsFile:write('case\tcapture\tframe\tstate_7fdf\tslot\tactive\tvisible\tsubtitle_hint\t' ..
  'x\ty\twidth\theight\traw_x\traw_y\tpattern_word\tpattern_base_word\t' ..
  'attr\tpalette\tpriority\thflip\tvflip\traw8\n')
groupsFile:write('case\tcapture\tframe\tgroup\tx0\ty0\tx1\ty1\twidth\theight\t' ..
  'sprite_count\tslots\tpattern_bases\n')

local function capture(caseLabel)
  captureSeq = captureSeq + 1
  local all, gameVisible = {}, {}
  local activeCount, visibleCount, subtitleCount = 0, 0, 0
  local state = rb(0x7FDF, MEM)
  for slot = 0, 63 do
    local s = sprite(slot)
    all[#all + 1] = s
    if s.active then activeCount = activeCount + 1 end
    if s.visible then visibleCount = visibleCount + 1 end
    if s.subtitle then subtitleCount = subtitleCount + 1 end
    if s.visible and not s.subtitle then gameVisible[#gameVisible + 1] = s end
    slotsFile:write(string.format(
      '%s\t%d\t%d\t%02X\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%04X\t%04X\t%04X\t%d\t%d\t%d\t%d\t%s\n',
      caseLabel, captureSeq, frame, state, s.slot, s.active and 1 or 0,
      s.visible and 1 or 0, s.subtitle and 1 or 0, s.x, s.y, s.width,
      s.height, s.rawX, s.rawY, s.pattern, s.patternBase, s.attr, s.palette,
      s.priority, s.hflip, s.vflip, s.raw))
  end
  local groups = components(gameVisible)
  for i, g in ipairs(groups) do
    groupsFile:write(string.format(
      '%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%s\n',
      caseLabel, captureSeq, frame, i, g.x0, g.y0, g.x1, g.y1,
      g.x1 - g.x0 + 1, g.y1 - g.y0 + 1, #g.slots,
      table.concat(g.slots, ','), table.concat(g.patterns, ',')))
  end
  slotsFile:flush(); groupsFile:flush()
  emu.log(string.format(
    'SUB 0.4.24 ★ %s CAPTURED: active=%d visible=%d subtitle_hint=%d game_groups=%d f=%d',
    caseLabel, activeCount, visibleCount, subtitleCount, #groups, frame))
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
  slotsFile:close(); groupsFile:close()
  emu.log('SUB 0.4.24 saved: ' .. SLOTS_OUT)
  emu.log('SUB 0.4.24 saved: ' .. GROUPS_OUT)
end, emu.eventType.scriptEnded)

emu.log('SUB 0.4.24 loaded -- portrait L/C/R occupancy comparison / read-only')
emu.log('  Q=L W=C E=R · A=LC S=LR D=CR · F=LCR · G=NONE · R=OTHER')
emu.log('  output slots:  ' .. SLOTS_OUT)
emu.log('  output groups: ' .. GROUPS_OUT)
