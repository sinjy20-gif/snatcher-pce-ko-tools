-- 0.4.11
--
-- ADPCM_008FA4_FFFF_0E 정지 지점 전용 관찰 프로브.
-- 자막/AC/VRAM/CPU 메모리를 절대 쓰지 않는다. 로그 파일만 쓴다.
--
-- 사용법
--   1) 정상 0.4.6.10 BIOS + 0.4.6.10 디스크로 실행
--   2) 이 Lua만 로드하고 해당 음성 직전 세이브에서 재현
--   3) 멈추면 E 키를 눌러 마지막 링버퍼를 dump
-- 출력: C:\\snatcher\\dump\\probe_voice_freeze_008FA4_irq_writer_0411.tsv

local OUT = "C:\\snatcher\\dump\\probe_voice_freeze_008FA4_irq_writer_0411.tsv"
local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce
local TARGET_SECTOR = 0x008FA4
local TARGET_END = 0xFFFF
local TARGET_RATE = 0x0E
local RING_SIZE = 600
local AFTER_END_FRAMES = 180

local ring, ringPos, ringCount = {}, 0, 0
local lockRing, lockPos, lockCount = {}, 0, 0
local irqWaitFrame, irqWaitCount = -1, 0
local irqFirstRing, irqFirstCount = {}, 0
local frame = 0
local active = false
local ended = false
local startFrame = nil
local endFrame = nil
local dumped = false
local lastPlaying = false
local keyHeld = false

local function byte(addr)
  return emu.read(addr & 0xFFFF, MEM) or 0
end

local function word(addr)
  return byte(addr) | (byte(addr + 1) << 8)
end

local function state()
  local ok, s = pcall(emu.getState)
  return ok and s or {}
end

local function number(s, key)
  local v = s[key]
  return type(v) == "number" and v or 0
end

local function currentKey(s)
  local sector = number(s, "cdrom.scsi.sector")
  local readAddress = number(s, "cdrom.adpcm.readAddress")
  local length = number(s, "cdrom.adpcm.adpcmLength")
  local rate = number(s, "cdrom.adpcm.playbackRate")
  local finish = (readAddress + length) & 0xFFFF
  return sector, finish, rate
end

local function push(tag, address)
  local s = state()
  ringPos = (ringPos % RING_SIZE) + 1
  ringCount = math.min(ringCount + 1, RING_SIZE)
  ring[ringPos] = {
    frame = frame,
    tag = tag,
    address = address or 0,
    pc = number(s, "cpu.pc"),
    sp = number(s, "cpu.sp"),
    a = number(s, "cpu.a"),
    x = number(s, "cpu.x"),
    y = number(s, "cpu.y"),
    mpr2 = number(s, "memoryManager.mpr[2]"),
    mpr7 = number(s, "memoryManager.mpr[7]"),
    irqMask = byte(0x1802),
    irqStatus = byte(0x1803),
    selector = string.format("%02X %02X %02X %02X %02X %02X",
      byte(0x5CEE), byte(0x5CEF), byte(0x5CF0),
      byte(0x5CF1), byte(0x5CF2), byte(0x5CF3)),
    engine165 = byte(0x5B80 + 165),
    engine167 = byte(0x5B80 + 167),
    engine276 = byte(0x5B80 + 276),
    engine281 = byte(0x5B80 + 281),
    adpcmPlaying = s["cdrom.adpcm.playing"] == true and 1 or 0,
    adpcmRead = number(s, "cdrom.adpcm.readAddress"),
    adpcmLength = number(s, "cdrom.adpcm.adpcmLength"),
    adpcmRate = number(s, "cdrom.adpcm.playbackRate"),
    cdSector = number(s, "cdrom.scsi.sector"),
    cdAudioSector = number(s, "cdrom.audioPlayer.currentSector"),
    lockF4 = byte(0x20F4),
    lockF5 = byte(0x20F5),
    lockF6 = byte(0x20F6),
    irqF0 = byte(0x20F0),
    irqF1 = byte(0x20F1),
    irqF2 = byte(0x20F2),
    irqF3 = byte(0x20F3),
    cpuP = number(s, "cpu.p"),
  }
end

local function writeDump(reason)
  if dumped then return end
  dumped = true
  local f = io.open(OUT, "w")
  if not f then
    emu.log("VOICE FREEZE PROBE: cannot open " .. OUT)
    return
  end
  local s = state()
  local sector, finish, rate = currentKey(s)
  f:write("# PROBE_VOICE_FREEZE 0.4.11\n")
  f:write("# reason=" .. reason .. " frame=" .. frame ..
    " active=" .. tostring(active) .. " ended=" .. tostring(ended) .. "\n")
  f:write(string.format("# current_key=ADPCM_%06X_%04X_%02X\n", sector, finish, rate))
  f:write(string.format("# pc=$%04X sp=$%02X a=$%02X x=$%02X y=$%02X p=$%02X irq_mask=$%02X irq_status=$%02X lock20F4=$%02X lock20F5=$%02X lock20F6=$%02X\n",
    number(s, "cpu.pc"), number(s, "cpu.sp"), number(s, "cpu.a"),
    number(s, "cpu.x"), number(s, "cpu.y"), number(s, "cpu.p"), byte(0x1802), byte(0x1803),
    byte(0x20F4), byte(0x20F5), byte(0x20F6)))
  f:write("frame\ttag\taddress\tpc\tsp\ta\tx\ty\tp\tmpr2\tmpr7\tirq_mask\tirq_status\tselector\teng165\teng167\teng276\teng281\tadpcm_playing\tadpcm_read\tadpcm_length\tadpcm_rate\tcd_sector\tcd_audio_sector\tlock20F4\tlock20F5\tlock20F6\tirq20F0\tirq20F1\tirq20F2\tirq20F3\n")
  local first = ringCount == RING_SIZE and (ringPos % RING_SIZE) + 1 or 1
  for i = 0, ringCount - 1 do
    local e = ring[(first + i - 1) % RING_SIZE + 1]
    f:write(string.format("%d\t%s\t$%04X\t$%04X\t$%02X\t$%02X\t$%02X\t$%02X\t$%02X\t$%02X\t$%02X\t$%02X\t$%02X\t%s\t$%02X\t$%02X\t$%02X\t$%02X\t%d\t$%04X\t$%04X\t$%02X\t$%06X\t$%06X\t$%02X\t$%02X\t$%02X\t$%02X\t$%02X\t$%02X\t$%02X\n",
      e.frame, e.tag, e.address, e.pc, e.sp, e.a, e.x, e.y,
      e.cpuP, e.mpr2, e.mpr7, e.irqMask, e.irqStatus, e.selector,
      e.engine165, e.engine167, e.engine276, e.engine281,
      e.adpcmPlaying, e.adpcmRead, e.adpcmLength, e.adpcmRate,
      e.cdSector, e.cdAudioSector, e.lockF4, e.lockF5, e.lockF6,
      e.irqF0, e.irqF1, e.irqF2, e.irqF3))
  end
  f:write("\n# lock writes (always retained, newest 128)\n")
  f:write("frame\taddress\tpc\tsp\ta\tx\ty\tp\twrite_value\tf4\tf5\tf6\tirq_mask\tirq_status\n")
  local lockFirst = lockCount == 128 and (lockPos % 128) + 1 or 1
  for i = 0, lockCount - 1 do
    local e = lockRing[(lockFirst + i - 1) % 128 + 1]
    f:write(string.format("%d\t$%04X\t$%04X\t$%02X\t$%02X\t$%02X\t$%02X\t$%02X\t$%02X\t$%02X\t$%02X\t$%02X\t$%02X\t$%02X\n",
      e.frame, e.address, e.pc, e.sp, e.a, e.x, e.y, e.p, e.value,
      e.f4, e.f5, e.f6, e.irqMask, e.irqStatus))
  end
  f:write("\n# first IRQ events (first 32 after target START)\n")
  f:write("frame\ttag\taddress\tpc\tsp\ta\tx\ty\tp\t20F0\t20F1\t20F2\t20F3\t20F4\t20F5\t20F6\tirq_mask\tirq_status\n")
  for i = 1, irqFirstCount do
    local e = irqFirstRing[i]
    f:write(string.format("%d\t%s\t$%04X\t$%04X\t$%02X\t$%02X\t$%02X\t$%02X\t$%02X\t$%02X\t$%02X\t$%02X\t$%02X\t$%02X\t$%02X\t$%02X\t$%02X\t$%02X\n",
      e.frame, e.tag, e.address, e.pc, e.sp, e.a, e.x, e.y, e.p,
      e.f0, e.f1, e.f2, e.f3, e.f4, e.f5, e.f6, e.irqMask, e.irqStatus))
  end
  f:close()
  emu.log("★ VOICE FREEZE PROBE dump -> " .. OUT .. " (" .. reason .. ")")
end

local pushFirstIrq

local function mark(tag, address)
  if not active then return end
  push(tag, address)
  if tag:sub(1, 4) == "IRQ_" then pushFirstIrq(tag, address) end
  if tag == "IRQ_LOCK_WAIT" then
    if irqWaitFrame ~= frame then irqWaitFrame, irqWaitCount = frame, 0 end
    irqWaitCount = irqWaitCount + 1
    if irqWaitCount == 8 and not dumped then
      writeDump("auto IRQ loop: E736 x8 in one frame")
    end
  end
end

-- $20F4-$20F6 기록은 active 여부와 무관하게 별도 보존한다.
local function pushLock(address)
  local s = state()
  lockPos = (lockPos % 128) + 1
  lockCount = math.min(lockCount + 1, 128)
  lockRing[lockPos] = {
    frame = frame, address = address or 0,
    pc = number(s, "cpu.pc"), sp = number(s, "cpu.sp"),
    a = number(s, "cpu.a"), x = number(s, "cpu.x"), y = number(s, "cpu.y"),
    p = number(s, "cpu.p"), value = byte(address or 0),
    f4 = byte(0x20F4), f5 = byte(0x20F5), f6 = byte(0x20F6),
    irqMask = byte(0x1802), irqStatus = byte(0x1803),
  }
end

pushFirstIrq = function(tag, address)
  if irqFirstCount >= 32 then return end
  local s = state()
  irqFirstCount = irqFirstCount + 1
  irqFirstRing[irqFirstCount] = {
    frame = frame, tag = tag, address = address or 0,
    pc = number(s, "cpu.pc"), sp = number(s, "cpu.sp"),
    a = number(s, "cpu.a"), x = number(s, "cpu.x"), y = number(s, "cpu.y"),
    p = number(s, "cpu.p"), f0 = byte(0x20F0), f1 = byte(0x20F1),
    f2 = byte(0x20F2), f3 = byte(0x20F3), f4 = byte(0x20F4),
    f5 = byte(0x20F5), f6 = byte(0x20F6),
    irqMask = byte(0x1802), irqStatus = byte(0x1803),
  }
end

-- 음성 시작/종료는 관찰만 한다. 키가 일치할 때만 추적을 켠다.
emu.addEventCallback(function()
  frame = frame + 1
  local s = state()
  local playing = s["cdrom.adpcm.playing"] == true
  if playing and not lastPlaying then
    local sector, finish, rate = currentKey(s)
    if sector == TARGET_SECTOR and finish == TARGET_END and rate == TARGET_RATE then
      active, ended, dumped = true, false, false
      startFrame = frame
      push("VOICE_START", 0)
      emu.log(string.format("VOICE FREEZE TARGET START frame=%d key=ADPCM_%06X_%04X_%02X",
        frame, sector, finish, rate))
    end
  elseif not playing and lastPlaying and active and not ended then
    ended = true
    endFrame = frame
    push("VOICE_END", 0)
    emu.log(string.format("VOICE FREEZE TARGET END frame=%d duration=%.3fs",
      frame, (frame - (startFrame or frame)) / 60))
  end
  lastPlaying = playing

  if active and ended and endFrame and frame - endFrame >= AFTER_END_FRAMES then
    writeDump("180 frames after VOICE_END")
  end

  local ok, down = pcall(function() return emu.isKeyPressed("E") end)
  if ok and down and not keyHeld then writeDump("manual E") end
  keyHeld = ok and down or false
end, emu.eventType.endFrame)

-- 정지 직전 실행 경로를 낮은 비용으로 표시한다.
local execPoints = {
  {0x5E40, "PRELOAD"}, {0x606F, "SAT_BUILD"}, {0x6463, "RENDER"},
  {0x6527, "SAT_DMA"}, {0x66E5, "RECEPTION"}, {0x66F8, "RECEPTION_NEXT"},
  {0xFEC4, "CAVE"}, {0xFFD4, "BIOS_DISPATCH"}, {0xF054, "BIOS_REPAIR"},
  {0xE733, "IRQ_LOCK_BRANCH"}, {0xE736, "IRQ_LOCK_WAIT"},
  {0xE739, "IRQ_PHA"}, {0xE73B, "IRQ_HANDLER"}, {0xE73C, "IRQ_BSR"},
  {0xE73E, "IRQ_PULL"}, {0xE741, "IRQ_RTI"}, {0xE742, "IRQ_SUB"},
  {0xE74A, "IRQ_BODY"}, {0xE7B4, "IRQ_BODY2"}, {0xE7C8, "IRQ_BODY3"},
  {0xE844, "IRQ_BODY4"}, {0xE870, "IRQ_ENTRY"},
}
for _, p in ipairs(execPoints) do
  emu.addMemoryCallback(function() mark(p[2], p[1]) end,
    emu.callbackType.exec, p[1], p[1], CPU, MEM)
end

-- 자막 RAM/엔진과 CD IRQ 상태가 실제로 건드려졌는지만 기록한다.
emu.addMemoryCallback(function(address) mark("RAM_READ", address) end,
  emu.callbackType.read, 0x5B80, 0x5E3F, CPU, MEM)
emu.addMemoryCallback(function(address) mark("RAM_WRITE", address) end,
  emu.callbackType.write, 0x5B80, 0x5E3F, CPU, MEM)
emu.addMemoryCallback(function(address) mark("IRQ_WRITE", address) end,
  emu.callbackType.write, 0x1802, 0x1803, CPU, MEM)
emu.addMemoryCallback(function(address)
  pushLock(address)
  if active then mark("LOCK_WRITE", address) end
end,
  emu.callbackType.write, 0x20F0, 0x20F6, CPU, MEM)
emu.addMemoryCallback(function(address)
  if active then mark("IRQ_STATE_READ", address) end
end, emu.callbackType.read, 0x20F0, 0x20F6, CPU, MEM)
emu.addMemoryCallback(function(address) mark("IRQ_READ", address) end,
  emu.callbackType.read, 0x1802, 0x1803, CPU, MEM)

emu.addEventCallback(function()
  if active and not dumped then push("FRAME", 0) end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if active and not dumped then writeDump("script stopped") end
end, emu.eventType.scriptEnded)

emu.log("PROBE_VOICE_FREEZE 0.4.11 loaded -- target ADPCM_008FA4_FFFF_0E")
emu.log("  관찰 전용 · 정지 시 E 키로 " .. OUT .. " 저장")
