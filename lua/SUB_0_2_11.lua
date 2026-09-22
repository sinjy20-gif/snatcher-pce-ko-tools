-- SUB 0.2.11 -- deferred preload POC, mapping-aware.
-- $66E5 is a different overlay at the title screen.  Wait until the exact
-- Korean JSR $5E40 hook is mapped, then replace it with the native renderer.
-- At reception action UI restore JSR $5E40.  No disc/AC/VRAM writes.
-- Restart Mesen after this temporary RAM-only test.
local MEM, CPU = emu.memType.pceMemory, emu.memType.cpu
local RENDER = 0x66E5
local HOOK = { 0x20, 0x40, 0x5E }
local ORIGINAL = { 0xAD, 0x71, 0x34 }
local deferred, rearmed, warned = false, false, false
local function b(at) return emu.read(at, MEM) or 0 end
local function is(bytes)
  return b(RENDER) == bytes[1] and b(RENDER + 1) == bytes[2] and b(RENDER + 2) == bytes[3]
end
local function put(bytes)
  for i = 1, #bytes do emu.write(RENDER + i - 1, bytes[i], MEM) end
end
emu.addMemoryCallback(function()
  if not deferred then
    if is(HOOK) then
      put(ORIGINAL); deferred = true
      emu.log('SUB 0.2.11 PASS: Korean hook mapped; opening preload deferred')
    elseif not warned then
      warned = true
      emu.log(string.format('SUB 0.2.11 waiting: title overlay $66E5=%02X %02X %02X',
        b(RENDER), b(RENDER + 1), b(RENDER + 2)))
    end
    return
  end
  if rearmed then return end
  local ptr = b(0x3471) | (b(0x3472) << 8)
  if ptr == 0x3499 or ptr == 0x349A then
    put(HOOK); rearmed = true
    emu.log('SUB 0.2.11 PASS: reception UI reached; normal preload re-armed')
  end
end, emu.callbackType.exec, RENDER, RENDER, emu.cpuType.pce, CPU)
emu.addEventCallback(function()
  emu.log(string.format('SUB 0.2.11 ended: deferred=%s rearmed=%s; restart Mesen before another run',
    tostring(deferred), tostring(rearmed)))
end, emu.eventType.scriptEnded)
emu.log('SUB 0.2.11 loaded -- mapping-aware opening preload deferral POC')
emu.log('  load before NEW GAME; no-skip to reception action UI')
