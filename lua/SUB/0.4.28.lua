-- SUB 0.4.28 -- prove single-path move: new $1600 versus old $7900.
--
-- Wraps 0.4.27 and audits both pattern windows.  Nonzero data at $7900 is not
-- evidence of a live old renderer; only a new write or a palette-F SATB
-- reference is.  One forced voice is enough to distinguish these cases:
--
--   PASS  new writes/refs > 0, old writes/refs = 0
--   FAIL  old writes or palette-F refs > 0  (old and new paths both alive)
--
-- Do not run 0.4.27 separately with this file; 0.4.28 loads it itself.

local VRAM = emu.memType.pceVideoRam
local NEW_FIRST, NEW_LAST = 0x1600, 0x1ABF
local OLD_FIRST, OLD_LAST = 0x7900, 0x7DBF
local stamp = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/sub_0_4_28_dual_path_' .. stamp .. '.tsv'
local file = assert(io.open(OUT, 'w'))
file:write('frame\tevent\tnew_write_bytes\told_write_bytes\tnew_palette_f_slots\t' ..
           'old_palette_f_slots\tnew_slots\told_slots\n')

local frame, closed = 0, false
local newWrites, oldWrites = 0, 0
local pendingNew, pendingOld = 0, 0
local maxNewSlots, maxOldSlots = 0, 0
local lastNewSlots, lastOldSlots = -1, -1

local function watchNew() newWrites = newWrites + 1; pendingNew = pendingNew + 1 end
local function watchOld() oldWrites = oldWrites + 1; pendingOld = pendingOld + 1 end

local newCallback = pcall(function()
  emu.addMemoryCallback(watchNew, emu.callbackType.write,
    NEW_FIRST * 2, NEW_LAST * 2 + 1, nil, VRAM)
end)
local oldCallback = pcall(function()
  emu.addMemoryCallback(watchOld, emu.callbackType.write,
    OLD_FIRST * 2, OLD_LAST * 2 + 1, nil, VRAM)
end)

local function rb(at) return emu.read(at, VRAM) or 0 end

local function inRange(base, first, last)
  return base >= first and base <= last
end

local function subtitleSlots()
  local new, old = {}, {}
  for slot = 0, 63 do
    local at = 0x2000 + slot * 8
    local y = rb(at) | (rb(at + 1) << 8)
    local x = rb(at + 2) | (rb(at + 3) << 8)
    local pattern = rb(at + 4) | (rb(at + 5) << 8)
    local attr = rb(at + 6) | (rb(at + 7) << 8)
    if (y ~= 0 or x ~= 0 or pattern ~= 0 or attr ~= 0) and
       (attr & 0x0F) == 0x0F then
      local base = (pattern & 0x07FF) << 5
      if inRange(base, NEW_FIRST, NEW_LAST) then
        new[#new + 1] = string.format('%d:$%04X', slot, base)
      elseif inRange(base, OLD_FIRST, OLD_LAST) then
        old[#old + 1] = string.format('%d:$%04X', slot, base)
      end
    end
  end
  return new, old
end

local function row(event, new, old)
  file:write(string.format('%d\t%s\t%d\t%d\t%d\t%d\t%s\t%s\n',
    frame, event, newWrites, oldWrites, #new, #old,
    table.concat(new, ','), table.concat(old, ',')))
  file:flush()
end

-- Register the audit before loading the writer so the first upload is visible.
dofile('C:/snatcher/lua/SUB/0.4.27.lua')

emu.addEventCallback(function()
  frame = frame + 1
  local new, old = subtitleSlots()
  maxNewSlots, maxOldSlots = math.max(maxNewSlots, #new), math.max(maxOldSlots, #old)

  if pendingNew > 0 or pendingOld > 0 then
    row('WRITE', new, old)
    pendingNew, pendingOld = 0, 0
  end
  if #new ~= lastNewSlots or #old ~= lastOldSlots then
    row('REF_CHANGE', new, old)
    lastNewSlots, lastOldSlots = #new, #old
  end

  local oldLive = oldWrites > 0 or maxOldSlots > 0
  emu.drawString(4, 34, string.format(
    '0.4.28 NEW W:%d S:%d  OLD W:%d S:%d',
    newWrites, maxNewSlots, oldWrites, maxOldSlots),
    oldLive and 0xFF4040 or 0x40FF40, 0x000000)
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if closed then return end
  closed = true
  local pass = newCallback and oldCallback and newWrites > 0 and
               maxNewSlots > 0 and oldWrites == 0 and maxOldSlots == 0
  local new, old = subtitleSlots()
  row(pass and 'SUMMARY_PASS' or 'SUMMARY_FAIL', new, old)
  file:close()
  emu.log(string.format(
    'SUB 0.4.28 ★ %s new(W=%d,S=%d) old(W=%d,S=%d) callbacks=%s/%s',
    pass and 'PASS' or 'FAIL', newWrites, maxNewSlots, oldWrites, maxOldSlots,
    tostring(newCallback), tostring(oldCallback)))
  emu.log('SUB 0.4.28 saved: ' .. OUT)
end, emu.eventType.scriptEnded)

emu.log('SUB 0.4.28 loaded -- dual path proof $1600(new) vs $7900(old)')
emu.log('  run this file alone; one forced voice is enough, then Stop')
emu.log('  PASS: NEW W/S > 0 and OLD W/S = 0')
emu.log('  output: ' .. OUT)

