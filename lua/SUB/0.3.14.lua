-- SUB 0.3.14 -- CD reads after AC preload (read-only)
-- May be loaded while the game is already running. Repeat the city scene if needed.

local MEM, AC, CPU = emu.memType.pceMemory, emu.memType.pceArcadeCardRam, emu.memType.cpu
local OUT = 'C:/snatcher/dump/sub_0_3_14_cd_after_preload.tsv'
local PAYLOAD_LO, PAYLOAD_HI = 0x045D68, 0x045FBB
local frame, reads, payloadReads, gameReads = 0, 0, 0, 0
local firstRead, lastRead = nil, nil
local file = assert(io.open(OUT, 'w'))
file:write('frame\tlba\tcount\tend_lba\tkind\tcaller\n')

local function byte(a) return emu.read(a, MEM) or 0 end
local function acReady()
  return (emu.read(0x10000, AC) or 0) == 0xAC
     and (emu.read(0x10001, AC) or 0) == 0x15
     and (emu.read(0x10002, AC) or 0) == 0x51
     and (emu.read(0x10003, AC) or 0) == 0
     and (emu.read(0x10004, AC) or 0) == 1
     and (emu.read(0x10005, AC) or 0) == 2
end
local function caller()
  local ok, s = pcall(emu.getState)
  if not ok or not s then return 0 end
  local sp = s['cpu.sp'] or 0
  local lo = byte(0x2100 + ((sp + 2) % 256))
  local hi = byte(0x2100 + ((sp + 3) % 256))
  return (lo + hi * 256 + 1) % 0x10000
end

-- $F104 return: $FC-$FE contains the absolute LBA.
emu.addMemoryCallback(function()
  if not acReady() then return end
  local lba = byte(0x20FC) * 0x10000 + byte(0x20FD) * 0x100 + byte(0x20FE)
  local count = byte(0x20F8); if count == 0 then count = 1 end
  local last = lba + count - 1
  local payload = last >= PAYLOAD_LO and lba <= PAYLOAD_HI
  local kind = payload and 'AC_PAYLOAD' or 'GAME_DATA'
  reads = reads + 1
  if payload then payloadReads = payloadReads + 1 else gameReads = gameReads + 1 end
  firstRead = firstRead or frame; lastRead = frame
  local from = caller()
  file:write(string.format('%d\t%06X\t%d\t%06X\t%s\t%04X\n',
    frame, lba, count, last, kind, from)); file:flush()
  emu.log(string.format('SUB 0.3.14 CD f=%d %06X-%06X (%d) %s caller=%04X',
    frame, lba, last, count, kind, from))
end, emu.callbackType.exec, 0xF123, 0xF123, emu.cpuType.pce, CPU)

emu.addEventCallback(function()
  frame = frame + 1
  if lastRead and frame - lastRead == 60 then
    emu.log(string.format('SUB 0.3.14 SUMMARY reads=%d · AC=%d · GAME=%d · span=%df',
      reads, payloadReads, gameReads, lastRead - firstRead + 1))
  end
end, emu.eventType.endFrame)

emu.log('SUB 0.3.14 loaded -- post-preload CD audit / read-only')
emu.log('  현재 장면을 진행하거나 다시 재현 · AC_PAYLOAD면 우리 적재, GAME_DATA면 원래 장면 데이터')
emu.log('  output: ' .. OUT)
