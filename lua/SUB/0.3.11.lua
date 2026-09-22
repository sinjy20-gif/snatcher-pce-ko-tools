-- SUB 0.3.11 -- 0.4.6.0 true BIOS preload verifier (read-only)
-- Load this one file, power-cycle, and do not skip the opening.

local AC, MEM, CPU = emu.memType.pceArcadeCardRam, emu.memType.pceMemory, emu.memType.cpu
local frame, readyFrame, lookupFrame = 0, nil, nil
local payloadReads, latePayloadReads, demandInit = 0, 0, false
local PAYLOAD_LO, PAYLOAD_HI = 0x045D68, 0x045FBB -- LBA 286056..286651 exact

local function readFile(path)
  local f = assert(io.open(path, 'rb'), 'cannot open ' .. path)
  local d = f:read('*a'); f:close(); return d
end

local translation = readFile('C:/snatcher/build/patch/TEST/0.4.5.9-signtest-base/ac_dynamic_packs/disc_package_image.bin')
translation = translation:sub(1, 0x10000)
  .. string.char(0xAC, 0x15, 0x51, 0, 1, 2)
  .. translation:sub(0x10007)
local pack = readFile('C:/snatcher/build/cutscene_subs/subtitle_pack.bin')
local helper = readFile('C:/snatcher/build/cutscene_subs/resident_helper_slot_native_poll_0_8_3.bin')
local renderer = readFile('C:/snatcher/build/cutscene_subs/resident_renderer_slot_native_poll_0_8_4_r3.bin')

local function byte(addr, kind) return emu.read(addr, kind) or 0 end
local function ready()
  return byte(0x10000, AC) == 0xAC and byte(0x10001, AC) == 0x15
     and byte(0x10002, AC) == 0x51 and byte(0x10003, AC) == 0
     and byte(0x10004, AC) == 1 and byte(0x10005, AC) == 2
end
local function mismatch(blob, base)
  local bad = 0
  for i = 1, #blob do
    if byte(base + i - 1, AC) ~= blob:byte(i) then bad = bad + 1 end
  end
  return bad
end

emu.addEventCallback(function()
  frame = frame + 1
  if not readyFrame and ready() then
    readyFrame = frame
    emu.log(string.format('SUB 0.3.11 ★ BIOS PRELOAD READY f=%d · payload CD reads=%d',
                          frame, payloadReads))
  end
end, emu.eventType.endFrame)

-- $F104 return: absolute LBA is already in BIOS zero page $FC-$FE.
emu.addMemoryCallback(function()
  local lba = byte(0x20FC, MEM) * 0x10000 + byte(0x20FD, MEM) * 0x100 + byte(0x20FE, MEM)
  if lba >= PAYLOAD_LO and lba <= PAYLOAD_HI then
    payloadReads = payloadReads + 1
    if readyFrame then latePayloadReads = latePayloadReads + 1 end
    if payloadReads == 1 then
      emu.log(string.format('SUB 0.3.11 BIOS preload transfer begins f=%d LBA=%06X', frame, lba))
    end
  end
end, emu.callbackType.exec, 0xF123, 0xF123, emu.cpuType.pce, CPU)

emu.addMemoryCallback(function()
  demandInit = true
  emu.log('SUB 0.3.11 ★ FAIL: old demand init_store executed')
end, emu.callbackType.exec, 0xBD13, 0xBD13, emu.cpuType.pce, CPU)

emu.addMemoryCallback(function()
  if lookupFrame then return end
  lookupFrame = frame
  local bad1 = mismatch(translation, 0x000000)
  local bad2 = mismatch(pack, 0x1C0000)
  local bad3 = mismatch(helper, 0x1F1C00)
  local bad4 = mismatch(renderer, 0x1F1F00)
  local total = bad1 + bad2 + bad3 + bad4
  emu.log(string.format('SUB 0.3.11 first lookup f=%d · ready=%s · mismatch=%d · late_reads=%d',
                        frame, tostring(readyFrame), total, latePayloadReads))
  if readyFrame and readyFrame < frame and total == 0 and not demandInit
     and latePayloadReads == 0 then
    emu.log('SUB 0.3.11 ★ TRUE BIOS PRELOAD PASS: 장면 전 AC 완료 · 런타임 적재 0')
  else
    emu.log('SUB 0.3.11 ★ TRUE BIOS PRELOAD FAIL')
  end
end, emu.callbackType.exec, 0x5E40, 0x5E40, emu.cpuType.pce, CPU)

emu.log('SUB 0.3.11 loaded -- 0.4.6.0 true BIOS preload audit / read-only')
emu.log('  Power Cycle 후 노스킵: 로딩 위치 · 도시 · 코나미 간판 · 접수처 UI 확인')
