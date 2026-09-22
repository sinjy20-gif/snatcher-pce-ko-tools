-- SUB 0.4.72-controller-stage-pingpong
--
-- 0.4.60의 정상 요소(전체 KEY controller, Lua timer, stage 재무장)는 유지하고,
-- 조각 전환 때 색상 쓰레기를 만들 수 있는 allocator snapshot/restore 및 수동
-- SATB wipe는 사용하지 않는다.  대신 음성 키별로 측정한 두 안전 base를 조각마다
-- 번갈아 사용한다.  엔진이 새 SATB를 정상 생성하도록 그대로 둔다.
--
-- Power Cycle 후 이 파일 하나만 실행한다.

dofile('C:/snatcher/lua/SUB/0.4.58-controller-stage.lua')

local VERSION = '0.4.72-controller-stage-pingpong'
local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce

local ENGINE = 0x5B80
local COUNT_OK = ENGINE + 118
local SELECTOR = ENGINE + 345
-- 0.4.64/0.4.71 경로가 유지하던 record Y. 이 값이 틀리면 첫 셀과
-- 속성 필드의 해석이 어긋나 색상 쓰레기로 보일 수 있다.
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
    -- 미측정 키는 0.4.58의 기본 주소를 건드리지 않는다.  임의 주소를 골라
    -- 화면을 오염시키는 것보다, 화면의 "미등록" 표시로 발견하는 편이 안전하다.
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
    string.format('0.4.72 PINGPONG %d  %s  미등록 %d',
                  placed, flip and 'B' or 'A', missing),
    missing > 0 and 0xFFA000 or 0x80FFC0, 0x000000)
end, emu.eventType.endFrame)

emu.log(string.format('SUB %s armed -- 0.4.58 controller/stage + %d key pairs',
                      VERSION, pairCount))
emu.log('  allocator snapshot/restore OFF · fragment/end manual wipe OFF')
emu.log('  등록 키는 조각마다 A/B 교대 · 미등록 키는 기본 주소를 유지')
