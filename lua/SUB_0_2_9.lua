-- SUB 0.2.9 -- title-cache-restore bypass POC.
-- Test only: on the verified Bank $69 title-stub mapping, replace its entry
-- with JMP $73BD (the original scene spawn handler).  No disc/AC/VRAM writes.
-- Restart Mesen after the test; RAM is then fully restored from the disc.
local MEM, CPU = emu.memType.pceMemory, emu.memType.cpu
local STUB, ORIGINAL = 0x7CEF, 0x73BD
local installed, frame = false, 0

local function mpr3()
  local ok, s = pcall(emu.getState)
  if not ok or type(s) ~= 'table' then return -1 end
  return s['memoryManager.mpr[3]'] or s['mpr[3]'] or -1
end
local function b(at) return emu.read(at, MEM) or 0 end
emu.addMemoryCallback(function()
  if installed or mpr3() ~= 0x69 then return end
  local a, c, d = b(STUB), b(STUB + 1), b(STUB + 2)
  -- Verified 0.4.5.8 stub begins: LDY #$0A / LDA ($FA),Y.
  if a ~= 0xA0 or c ~= 0x0A or d ~= 0xB1 then
    emu.log(string.format('SUB 0.2.9 ABORT: $7CEF is %02X %02X %02X, not title stub', a, c, d))
    return
  end
  emu.write(STUB, 0x4C, MEM) -- JMP $73BD
  emu.write(STUB + 1, ORIGINAL & 0xFF, MEM)
  emu.write(STUB + 2, ORIGINAL >> 8, MEM)
  installed = true
  emu.log('SUB 0.2.9 PASS: title-cache restore bypassed ($7CEF -> $73BD)')
end, emu.callbackType.exec, STUB, STUB, emu.cpuType.pce, CPU)
emu.addEventCallback(function() frame = frame + 1 end, emu.eventType.endFrame)
emu.addEventCallback(function()
  emu.log(string.format('SUB 0.2.9 ended: bypass=%s; restart Mesen before any other test', installed and 'installed' or 'not-installed'))
end, emu.eventType.scriptEnded)
emu.log('SUB 0.2.9 loaded -- title cache restore bypass POC')
emu.log('  no disc/AC/VRAM writes; start a NEW GAME without skipping, then check reception action UI')
