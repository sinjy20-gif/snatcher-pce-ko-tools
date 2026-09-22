-- SUB 0.3.32 -- build 0.4.6.9 reception repair verifier / read-only.
--
-- Supersedes 0.3.30, which reported FAIL without being able to say why.
-- 0.3.30's finding was that $66F8 still read 4C 3F 68 when it executed, i.e.
-- the native guard never armed: 0.4.6.7/0.4.6.8 sampled $3471/$3472 after
-- JSR $5E40, and $5E40 overwrites that pointer with $5B90 on the reception
-- branch.  0.4.6.9 samples before the call.  This script checks each link of
-- that chain separately, so a failure says which link broke.
--
-- Power Cycle -> NOSKIP -> reception action menu.

local MEM, CPU = emu.memType.pceMemory, emu.memType.cpu
local VRAM = emu.memType.pceVideoRam
local WINDOW = 600        -- frames to keep looking for the repair
local HOLD = 180          -- frames to keep watching after it lands

local armed, entered, passed, failed = false, false, false, false
local waited, held, pass_frame, frame = 0, 0, 0, 0
local broke_after = nil

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

local function mismatches()
  local diff = 0
  for i = 0, 511 do
    if (emu.read(0x2C00 + i, VRAM) or 0) ~= CLEAN[i + 1] then diff = diff + 1 end
  end
  return diff
end

-- Link 1: the renderer reaches the reception string and our hook is live.
emu.addMemoryCallback(function()
  if armed or passed or failed then return end
  local ptr = byte(0x3471) | (byte(0x3472) << 8)
  if ptr ~= 0x3499 and ptr ~= 0x349A then return end
  armed = true
  emu.log(string.format('SUB 0.3.32 [1/4] guard window ptr=$%04X  $66E5=%s (want 20 D4 FF)',
    ptr, hex(0x66E5, 3)))
end, emu.callbackType.exec, 0x66E5, 0x66E5, emu.cpuType.pce, CPU)

-- Link 2: the native code armed.  $66E8 runs right after JSR $5E40 returns,
-- so by now the arm writes have happened or they never will.
emu.addMemoryCallback(function()
  if not armed or entered or passed or failed then return end
  local exit_bytes = hex(0x66F8, 3)
  local hook_bytes = hex(0x66E5, 3)
  if exit_bytes == '4C D4 FF' then
    emu.log(string.format('SUB 0.3.32 [2/4] ARMED  $66F8=%s  $66E5=%s (want 20 40 5E, unhooked)',
      exit_bytes, hook_bytes))
  else
    emu.log(string.format('SUB 0.3.32 [2/4] NOT ARMED  $66F8=%s  $66E5=%s', exit_bytes, hook_bytes))
    emu.log('SUB 0.3.32        the guard did not match -- this is the 0.4.6.8 failure')
    failed = true
  end
  entered = true
end, emu.callbackType.exec, 0x66E8, 0x66E8, emu.cpuType.pce, CPU)

-- Link 3: the repair routine was entered from the end-of-string exit.
emu.addMemoryCallback(function()
  if not armed or passed or failed then return end
  if hex(0x66F8, 3) ~= '4C D4 FF' then return end
  emu.log(string.format('SUB 0.3.32 [3/4] repair entered at $66F8 on frame %d', frame))
end, emu.callbackType.exec, 0x66F8, 0x66F8, emu.cpuType.pce, CPU)

-- Link 4: VRAM matches, and stays matching.
emu.addEventCallback(function()
  frame = frame + 1
  if not armed or failed then return end

  if not passed then
    waited = waited + 1
    local diff = mismatches()
    if diff == 0 then
      passed = true
      pass_frame = frame
      emu.log(string.format(
        'SUB 0.3.32 [4/4] REPAIR PASS: $2C00-$2DFF byte exact (%d frame(s) after arming)', waited))
      emu.log(string.format('SUB 0.3.32        hooks restored: $66E5=%s $66F8=%s (want 20 D4 FF / 4C 3F 68)',
        hex(0x66E5, 3), hex(0x66F8, 3)))
    elseif waited >= WINDOW then
      failed = true
      emu.log(string.format('SUB 0.3.32 [4/4] FAIL: mismatch=%d/512 after %d frames', diff, waited))
      emu.log(string.format('SUB 0.3.32        $66E5=%s $66F8=%s', hex(0x66E5, 3), hex(0x66F8, 3)))
    end
    return
  end

  -- Held check: does the game upload over $2C00-$2DFF again afterwards?
  if held < HOLD then
    held = held + 1
    if broke_after == nil and mismatches() ~= 0 then
      broke_after = frame - pass_frame
      emu.log(string.format(
        'SUB 0.3.32 NOTE: VRAM diverged again %d frame(s) after the repair -- the game re-uploads it',
        broke_after))
    end
    if held == HOLD and broke_after == nil then
      emu.log(string.format('SUB 0.3.32 held byte exact for %d frames after the repair', HOLD))
    end
  end
end, emu.eventType.endFrame)

emu.log('SUB 0.3.32 loaded -- 0.4.6.9 reception repair verifier / read-only')
emu.log('  Power Cycle -> NOSKIP -> 접수처 액션 메뉴')
