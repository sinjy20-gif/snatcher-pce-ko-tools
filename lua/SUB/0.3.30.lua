-- SUB 0.3.30 -- build 0.4.6.8 reception repair verifier / read-only.
-- Replaces 0.3.29, which could not verify 0.4.6.8 at all: it triggered on
-- $66E5 (no longer the repair site) and it compared VRAM on the single frame
-- after arming, so a repair that landed a frame later was reported as FAIL.
-- This one keeps checking until it matches, and says so when it never does.
--
-- Power Cycle, run NO-SKIP, and open the reception action menu once.

local MEM, VRAM, CPU = emu.memType.pceMemory, emu.memType.pceVideoRam, emu.memType.cpu
local WINDOW = 600          -- frames to keep looking after arming (~10 s)

local armed, entered, done, waited = false, false, false, 0

local CLEAN = {}
for i = 1, 512 do CLEAN[i] = 0 end
for _, off in ipairs({0,32,64,128,160,192,256,288,320,384,416,448}) do
  CLEAN[off + 1], CLEAN[off + 2] = 0xFF, 0xFF
end
for _, off in ipairs({0,32,64}) do
  for i = 3, 31, 2 do CLEAN[off + i + 1] = 0x80 end
end

local function bytes(addr, n)
  local out = {}
  for i = 0, n - 1 do out[i + 1] = emu.read(addr + i, MEM) or 0 end
  return string.format('%02X %02X %02X', out[1], out[2], out[3])
end

local function mismatches()
  local diff = 0
  for i = 0, 511 do
    if (emu.read(0x2C00 + i, VRAM) or 0) ~= CLEAN[i + 1] then diff = diff + 1 end
  end
  return diff
end

-- $66E5 is the per-character renderer entry.  Arming happens on the first
-- character of the reception string; the patch then unhooks $66E5 until the
-- repair runs, so this fires exactly once.
emu.addMemoryCallback(function()
  if armed or done then return end
  local ptr = (emu.read(0x3471, MEM) or 0) | ((emu.read(0x3472, MEM) or 0) << 8)
  if ptr ~= 0x3499 and ptr ~= 0x349A then return end
  armed = true
  emu.log(string.format('SUB 0.3.30 reception guard PASS ptr=$%04X', ptr))
end, emu.callbackType.exec, 0x66E5, 0x66E5, emu.cpuType.pce, CPU)

-- $66F8 is the end-of-string exit.  While armed it is JMP $FFD4.
emu.addMemoryCallback(function()
  if not armed or entered or done then return end
  entered = true
  emu.log(string.format('SUB 0.3.30 repair entry at $66F8, target %s', bytes(0x66F8, 3)))
end, emu.callbackType.exec, 0x66F8, 0x66F8, emu.cpuType.pce, CPU)

emu.addEventCallback(function()
  if not armed or done then return end
  waited = waited + 1
  local diff = mismatches()
  if diff == 0 then
    done = true
    emu.log(string.format(
      'SUB 0.3.30 * 0.4.6.8 REPAIR PASS: $2C00-$2DFF byte exact after %d frame(s)', waited))
    emu.log(string.format('SUB 0.3.30 hooks restored: $66E5=%s $66F8=%s (want 20 D4 FF / 4C 3F 68)',
      bytes(0x66E5, 3), bytes(0x66F8, 3)))
  elseif waited >= WINDOW then
    done = true
    emu.log(string.format(
      'SUB 0.3.30 REPAIR FAIL: mismatch=%d/512 B after %d frames', diff, waited))
    emu.log(string.format('SUB 0.3.30 entered repair: %s', tostring(entered)))
    emu.log(string.format('SUB 0.3.30 $66E5=%s $66F8=%s', bytes(0x66E5, 3), bytes(0x66F8, 3)))
  end
end, emu.eventType.endFrame)

emu.log('SUB 0.3.30 loaded -- 0.4.6.8 reception repair verifier / read-only')
emu.log('  Power Cycle -> NOSKIP -> open the reception action menu')
