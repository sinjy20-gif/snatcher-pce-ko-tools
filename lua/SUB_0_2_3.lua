-- SUB 0.2.3 -- read-only fragment render order map.
-- Load this file only. No CPU / AC / VRAM writes are made.
local MEM, VRAM, CPU = emu.memType.pceMemory, emu.memType.pceVideoRam, emu.memType.cpu
local ENGINE, REBUILD, GLYPH_DONE, SAT_DONE, STATE = 0x5B80, 0x5BA6, 0x5CB6, 0x6527, 0x7FDF
local armed, waitingSat, frame, seq = false, false, 0, 0

local function bytesAt(base)
  local n = 0
  for at = base * 2, (base + 1216) * 2 - 1 do
    if (emu.read(at, VRAM) or 0) ~= 0 then n = n + 1 end
  end
  return n
end
local function say(kind, extra)
  seq = seq + 1
  emu.log(string.format('SUB 0.2.3 ORDER %02d f=%d %-11s state=%02X ready=%02X elapsed=%02X %s',
    seq, frame, kind, emu.read(STATE, MEM) or 0, emu.read(ENGINE + 364, MEM) or 0,
    emu.read(ENGINE + 455, MEM) or 0, extra or ''))
end

emu.addMemoryCallback(function()
  local st = emu.getState()
  local ending = ((st['cdrom.adpcm.readAddress'] or 0) +
                  (st['cdrom.adpcm.adpcmLength'] or 0)) % 0x10000
  if ending == 0x6800 and (st['cdrom.adpcm.playbackRate'] or -1) == 0x0E then
    armed, waitingSat, seq = true, false, 0
    say('AD_PLAY', 'target=E6800_0E')
  end
end, emu.callbackType.exec, 0xF61A, 0xF61A, emu.cpuType.pce, CPU)

emu.addMemoryCallback(function()
  if not armed then return end
  waitingSat = true
  say('REBUILD', string.format('vram7900=%d/2432', bytesAt(0x7900)))
end, emu.callbackType.exec, REBUILD, REBUILD, emu.cpuType.pce, CPU)

emu.addMemoryCallback(function()
  if armed then say('GLYPH_DONE', string.format('vram7900=%d/2432', bytesAt(0x7900))) end
end, emu.callbackType.exec, GLYPH_DONE, GLYPH_DONE, emu.cpuType.pce, CPU)

emu.addMemoryCallback(function()
  if armed and waitingSat then
    waitingSat = false
    say('SAT_DONE', 'push loop returned')
  end
end, emu.callbackType.exec, SAT_DONE, SAT_DONE, emu.cpuType.pce, CPU)

emu.addEventCallback(function()
  frame = frame + 1
  if armed and (emu.read(STATE, MEM) or 0) == 0 and seq > 0 then
    say('VOICE_END', 'read-only end')
    armed, waitingSat = false, false
  end
end, emu.eventType.startFrame)

emu.log('SUB 0.2.3 loaded -- read-only render-order map / 이 파일 하나만 사용')
emu.log('  이전 SUB 0.2.1·0.2.2와 POC/PROBE는 중지할 것')
