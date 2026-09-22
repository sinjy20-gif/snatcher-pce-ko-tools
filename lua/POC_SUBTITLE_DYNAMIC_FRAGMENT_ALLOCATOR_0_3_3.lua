-- Dynamic subtitle VRAM allocator POC 0.3.3 -- render-chain audit.
--
-- 0.3.2 와 같은 BAT+SATB allocator / in-place 4-byte patch를 사용한다.
-- 추가로 한 음성에서 다음 사슬을 기록한다:
--
--   AD_PLAY -> renderer rebuild -> renderer push -> game $6463 -> SATB result
--
-- 자막 SAT 엔트리가 실제로 생긴 판만 그래픽 무결성 시험으로 인정한다.

SUB_ALLOCATOR_VERSION = '0.3.3'
SUB_ALLOCATOR_INPLACE_IMAGES = true
dofile('C:/snatcher/lua/POC_SUBTITLE_DYNAMIC_FRAGMENT_ALLOCATOR_0_3_1.lua')
SUB_ALLOCATOR_VERSION = nil
SUB_ALLOCATOR_INPLACE_IMAGES = nil

local MEM, VRAM, CPU = emu.memType.pceMemory, emu.memType.pceVideoRam, emu.memType.cpu
local ENGINE = 0x5B80
local REBUILD = ENGINE + 38                  -- $5BA6
local RENDER_PUSH = ENGINE + 315             -- $5CBB
local GAME_PUSH = 0x6463
local STATE = 0x7FDF
local READY = ENGINE + 364                   -- $5CEC
local COUNT = ENGINE + 365                   -- $5CED
local SELECTOR = ENGINE + 366                -- $5CEE
local SATB_BYTE = 0x2000

local frame = 0
local voice = 0
local rebuild = 0
local renderPush = 0
local gamePush = 0
local pendingEndFrame = false
local lastSummary = ''

local function m8(at) return emu.read(at, MEM) or 0 end
local function v8(at) return emu.read(at, VRAM) or 0 end
local function hexCpu(at, count)
  local out = {}
  for i = 0, count - 1 do out[#out + 1] = string.format('%02X', m8(at + i)) end
  return table.concat(out, ' ')
end

local function selectedBase()
  -- 현재 POC 후보는 $xx00 정렬이다. renderer offset 167 이 MAWR high.
  return (m8(ENGINE + 167) << 8) & 0x7FFF
end

local function subtitleSlots(base)
  local pat0 = (base >> 5) & 0x07FF
  local slots = {}
  for slot = 0, 63 do
    local at = SATB_BYTE + slot * 8
    local pattern = v8(at + 4) | (v8(at + 5) << 8)
    if pattern >= pat0 and pattern < pat0 + 38 then
      slots[#slots + 1] = string.format('%02d', slot)
    end
  end
  return slots
end

local function audit(tag)
  local base = selectedBase()
  local slots = subtitleSlots(base)
  local summary = string.format(
    '%s f=%d v=%d state=%02X magic=%s ready=%02X count=%d selector=%s base=$%04X SATB=%d[%s] push=%d/%d',
    tag, frame, voice, m8(STATE), hexCpu(ENGINE, 3), m8(READY), m8(COUNT),
    hexCpu(SELECTOR, 6), base, #slots, table.concat(slots, ','), renderPush, gamePush)
  if summary ~= lastSummary then
    emu.log(summary)
    lastSummary = summary
  end
end

-- allocator의 AD_PLAY callback 뒤에 등록되므로, 같은 진입점에서 패치 후 상태를 본다.
emu.addMemoryCallback(function()
  voice = voice + 1
  rebuild, renderPush, gamePush = 0, 0, 0
  pendingEndFrame = true
  audit('SUB 0.3.3 AD_PLAY')
end, emu.callbackType.exec, 0xF61A, 0xF61A, emu.cpuType.pce, CPU)

-- allocator가 이 주소에서 CPU renderer 피연산자를 먼저 바꾼 뒤 이 callback이 돈다.
emu.addMemoryCallback(function()
  rebuild = rebuild + 1
  pendingEndFrame = true
  audit(string.format('SUB 0.3.3 REBUILD#%d PRE', rebuild))
end, emu.callbackType.exec, REBUILD, REBUILD, emu.cpuType.pce, CPU)

emu.addMemoryCallback(function()
  renderPush = renderPush + 1
  pendingEndFrame = true
  audit(string.format('SUB 0.3.3 RENDER_PUSH#%d', renderPush))
end, emu.callbackType.exec, RENDER_PUSH, RENDER_PUSH, emu.cpuType.pce, CPU)

emu.addMemoryCallback(function()
  if renderPush > 0 then
    gamePush = gamePush + 1
    pendingEndFrame = true
    if gamePush <= 3 then audit(string.format('SUB 0.3.3 GAME_6463#%d', gamePush)) end
  end
end, emu.callbackType.exec, GAME_PUSH, GAME_PUSH, emu.cpuType.pce, CPU)

emu.addEventCallback(function()
  frame = frame + 1
  if pendingEndFrame then
    pendingEndFrame = false
    audit('SUB 0.3.3 FRAME_END')
  end
end, emu.eventType.endFrame)

emu.log('SUB 0.3.3 ready -- allocator + render-chain audit / 이 파일 하나만 사용')
emu.log('  합격: RENDER_PUSH > 0 · GAME_6463 > 0 · SATB > 0 · 화면 자막 표시 · 그림 정상')
