-- SUB 0.3.31 -- why 0.4.6.8's native guard never armed.  Read-only.
--
-- 0.3.30 showed $66F8 still holding 4C 3F 68 when it executed, so the native
-- arm never happened.  The suspected cause: 0.3.24 (the proven POC) reads
-- $3471/$3472 at the $66E5 exec, BEFORE JSR $5E40 runs, while the native code
-- reads it AFTER.  This measures both values for the same invocation.
--
-- Power Cycle -> NOSKIP -> reception action menu -> Stop.

local MEM, CPU = emu.memType.pceMemory, emu.memType.cpu
local VRAM = emu.memType.pceVideoRam
local OUT = string.format('C:/snatcher/dump/sub_0_3_31_guard_%s.tsv',
                          os.date('%Y%m%d_%H%M%S'))
local f = assert(io.open(OUT, 'w'))
f:write('frame\tseq\tptr_before\tptr_after\ta_after\tbytes_66E5\tbytes_66F8\tstub_hits\n')
f:flush()

local frame, seq, stub_hits = 0, 0, 0
local pending, logged_pairs, watch, reported = false, 0, false, 0

local CLEAN = {}
for i = 1, 512 do CLEAN[i] = 0 end
for _, off in ipairs({0,32,64,128,160,192,256,288,320,384,416,448}) do
  CLEAN[off + 1], CLEAN[off + 2] = 0xFF, 0xFF
end
for _, off in ipairs({0,32,64}) do
  for i = 3, 31, 2 do CLEAN[off + i + 1] = 0x80 end
end

local function byte(at) return emu.read(at & 0xFFFF, MEM) or 0 end

local function hex(at, n)
  local t = {}
  for i = 0, n - 1 do t[#t + 1] = string.format('%02X', byte(at + i)) end
  return table.concat(t, ' ')
end

local function ptr() return byte(0x3471) | (byte(0x3472) << 8) end

local before = 0

-- Fires before JSR $5E40 executes: this is what 0.3.24 saw.
emu.addMemoryCallback(function()
  before = ptr()
  pending = true
  if before == 0x3499 or before == 0x349A then
    watch = true
    emu.log(string.format('SUB 0.3.31 GUARD WINDOW frame=%d ptr_before=$%04X 66E5=%s 66F8=%s',
      frame, before, hex(0x66E5, 3), hex(0x66F8, 3)))
  end
end, emu.callbackType.exec, 0x66E5, 0x66E5, emu.cpuType.pce, CPU)

-- Fires after JSR $5E40 returned: this is what the native guard reads.
emu.addMemoryCallback(function()
  if not pending then return end
  pending = false
  local after = ptr()
  local s = emu.getState() or {}
  local a = s['cpu.a'] or 0
  local interesting = (before >= 0x3490 and before <= 0x34B0)
  if logged_pairs < 40 or interesting then
    logged_pairs = logged_pairs + 1
    seq = seq + 1
    f:write(string.format('%d\t%d\t%04X\t%04X\t%02X\t%s\t%s\t%d\n',
      frame, seq, before, after, a, hex(0x66E5, 3), hex(0x66F8, 3), stub_hits))
    f:flush()
  end
  if before == 0x3499 or before == 0x349A then
    emu.log(string.format(
      'SUB 0.3.31   after JSR $5E40: ptr=$%04X A=$%02X  (native compares $3471 to $99/$9A)',
      after, a))
    emu.log(string.format('SUB 0.3.31   stub $FFD4 hits so far = %d', stub_hits))
  end
end, emu.callbackType.exec, 0x66E8, 0x66E8, emu.cpuType.pce, CPU)

-- Proves whether the BIOS stub is reached at all.
emu.addMemoryCallback(function()
  stub_hits = stub_hits + 1
  if stub_hits <= 5 then
    emu.log(string.format('SUB 0.3.31 stub $FFD4 hit #%d frame=%d ptr=$%04X',
      stub_hits, frame, ptr()))
  end
end, emu.callbackType.exec, 0xFFD4, 0xFFD4, emu.cpuType.pce, CPU)

emu.addEventCallback(function()
  frame = frame + 1
  if not watch or reported >= 6 then return end
  if frame % 30 ~= 0 then return end
  reported = reported + 1
  local diff = 0
  for i = 0, 511 do
    if (emu.read(0x2C00 + i, VRAM) or 0) ~= CLEAN[i + 1] then diff = diff + 1 end
  end
  emu.log(string.format('SUB 0.3.31 frame=%d mismatch=%d/512 66E5=%s 66F8=%s stub=%d',
    frame, diff, hex(0x66E5, 3), hex(0x66F8, 3), stub_hits))
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  f:close()
  emu.log(string.format('SUB 0.3.31 saved: %s   (stub hits total = %d)', OUT, stub_hits))
end, emu.eventType.scriptEnded)

emu.log('SUB 0.3.31 loaded -- native guard diagnosis / read-only')
emu.log('  Power Cycle -> NOSKIP -> 접수처 액션 메뉴 -> Stop')
emu.log('  output: ' .. OUT)
