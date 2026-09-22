-- SUB 0.2.10 -- defer first Korean preload to reception UI POC.
-- During the opening, restore the original $66E5 renderer entry so it cannot
-- initialise AC.  At the first reception action-label request ($3499/$349A),
-- restore JSR $5E40.  No disc/AC/VRAM writes. Restart Mesen after testing.
local MEM, CPU = emu.memType.pceMemory, emu.memType.cpu
local RENDER = 0x66E5
local HOOK = { 0x20, 0x40, 0x5E }       -- JSR $5E40, Korean preloader
local ORIGINAL = { 0xAD, 0x71, 0x34 }   -- original renderer first instruction
local deferred, rearmed = false, false
local function b(at) return emu.read(at, MEM) or 0 end
local function put(bytes)
  for i = 1, #bytes do emu.write(RENDER + i - 1, bytes[i], MEM) end
end

-- At the title screen this overlay is already mapped.  Refuse to run unless
-- it is exactly the known 0.4.5.8 renderer hook.
if b(RENDER) == HOOK[1] and b(RENDER + 1) == HOOK[2] and b(RENDER + 2) == HOOK[3] then
  put(ORIGINAL); deferred = true
  emu.log('SUB 0.2.10 PASS: opening preload deferred ($66E5 original)')
else
  emu.log(string.format('SUB 0.2.10 ABORT: $66E5=%02X %02X %02X, expected 20 40 5E',
    b(RENDER), b(RENDER + 1), b(RENDER + 2)))
end

emu.addMemoryCallback(function()
  if not deferred or rearmed then return end
  local ptr = b(0x3471) | (b(0x3472) << 8)
  if ptr ~= 0x3499 and ptr ~= 0x349A then return end
  put(HOOK); rearmed = true
  emu.log('SUB 0.2.10 PASS: reception UI reached; normal preload re-armed')
end, emu.callbackType.exec, RENDER, RENDER, emu.cpuType.pce, CPU)
emu.addEventCallback(function()
  emu.log(string.format('SUB 0.2.10 ended: deferred=%s rearmed=%s; restart Mesen before another run',
    tostring(deferred), tostring(rearmed)))
end, emu.eventType.scriptEnded)
emu.log('SUB 0.2.10 loaded -- opening preload deferral POC')
emu.log('  load at title, start NEW GAME without skipping, then inspect reception action UI')
