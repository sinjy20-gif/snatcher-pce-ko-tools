-- SUB 0.4.73-controller-stage-pingpong
-- 0.4.58 controller/stage + 측정된 키별 A/B ping-pong.
-- snapshot/restore와 fragment/end 수동 wipe는 쓰지 않는다.
-- 0.4.71과 동일하게 record Y=122를 count_ok에서 보정한다.

dofile('C:/snatcher/lua/SUB/0.4.58-controller-stage.lua')

local VERSION = '0.4.73-controller-stage-pingpong'
local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce
local ENGINE = 0x5B80
local COUNT_OK = ENGINE + 118
local SELECTOR = ENGINE + 345
local RECORD_Y = ENGINE + 440 + 3
local VRAM_LO, VRAM_HI, PAT_LO, ATTR = 144, 146, 255, 260

local PAIRS_PATH = 'C:/snatcher/build/cutscene_subs/vram_key_bases_pairs.lua'
local PAIRS = assert(dofile(PAIRS_PATH), '핑퐁 표를 못 읽었다: ' .. PAIRS_PATH)
local pairCount = 0
for _ in pairs(PAIRS) do pairCount = pairCount + 1 end
assert(pairCount > 0, '핑퐁 표가 비었다. build_vram_key_bases.py --pairs 를 먼저 실행한다')

local function keyHex()
  local bytes = {}
  for i = 0, 5 do
    bytes[i + 1] = string.format('%02X', emu.read(SELECTOR + i, MEM) or 0)
  end
  return table.concat(bytes)
end

local function place(base)
  emu.write(ENGINE + VRAM_LO, base & 0xFF, MEM)
  emu.write(ENGINE + VRAM_HI, base >> 8, MEM)
  emu.write(ENGINE + PAT_LO, (base >> 5) & 0xFF, MEM)
  emu.write(ENGINE + ATTR,
            0x80 | (((base >> 13) & 0x07) << 4) | 0x0F, MEM)
end

local flip, placed, missing = false, 0, 0
local lastKey, reportedMissing = nil, {}

emu.addMemoryCallback(function()
  if (emu.read(RECORD_Y, MEM) or 0) ~= 122 then
    emu.write(RECORD_Y, 122, MEM)
  end
end, emu.callbackType.exec, COUNT_OK, COUNT_OK, CPU, MEM)

emu.addMemoryCallback(function()
  local key = keyHex()
  local pair = PAIRS[key]
  if not pair then
    if not reportedMissing[key] then
      reportedMissing[key] = true
      missing = missing + 1
      emu.log(string.format('SUB %s ▲ 미등록 키 %s -- 기본 주소 유지', VERSION, key))
    end
    return
  end
  if key ~= lastKey then
    lastKey, flip = key, false
  else
    flip = not flip
  end
  local base = flip and pair[2] or pair[1]
  place(base)
  placed = placed + 1
  emu.log(string.format('SUB %s ★ PART %d %s -> $%04X',
                        VERSION, placed, flip and 'B' or 'A', base))
end, emu.callbackType.exec, COUNT_OK, COUNT_OK, CPU, MEM)

emu.addEventCallback(function()
  emu.drawString(4, 104,
    string.format('0.4.73 PINGPONG %d  %s  미등록 %d',
                  placed, flip and 'B' or 'A', missing),
    missing > 0 and 0xFFA000 or 0x80FFC0, 0x000000)
end, emu.eventType.endFrame)

emu.log(string.format('SUB %s armed -- 0.4.58 controller/stage + %d key pairs',
                      VERSION, pairCount))
emu.log('  record Y=122 · snapshot/restore OFF · fragment/end manual wipe OFF')
emu.log('  등록 키는 조각마다 A/B 교대 · 미등록 키는 기본 주소를 유지')
