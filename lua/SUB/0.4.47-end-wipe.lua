-- SUB 0.4.47-end-wipe -- 자막 종료 때 표시 슬롯만 즉시 와이프
--
-- 0.4.45의 팩/엔진/allocator는 그대로 쓴다. 자막이 끝나는 순간에도 SATB가
-- 한 프레임가량 옛 자막 슬롯을 들고 있으면, allocator가 되돌린 게임 패턴이
-- 그 슬롯을 통해 UI 조각처럼 보일 수 있다. 이 판은 패턴 VRAM을 건드리지 않고
-- 방금 자막 블록을 가리키는 palette-F SATB 항목만 0으로 만든다.
--
-- 사용: Power Cycle 뒤 다른 SUB Lua를 끄고 이 파일 하나만 실행한다.

local VERSION = '0.4.47-end-wipe'
local MEM  = emu.memType.pceMemory
local VRAM = emu.memType.pceVideoRam
local SPR  = emu.memType.pceSpriteRam

local STATE       = 0x7FDF
local SATB        = 0x2000
local BLOCK_WORDS = 19 * 0x40

local realLog = emu.log
local selected = {}
local selectedCount = 0

-- 0.4.45 안의 allocator가 고른 모든 조각 주소를 받는다. dofile 중 allocator가
-- emu.log를 한 겹 더 감싸도 그 안쪽 realLog가 이 함수라 PATCHED가 도착한다.
emu.log = function(message)
  local text = tostring(message)
  local hex = text:match('PATCHED base=%$(%x%x%x%x)')
  if hex then
    local base = tonumber(hex, 16)
    if not selected[base] then selectedCount = selectedCount + 1 end
    selected[base] = true
  end
  realLog(text)
end

dofile('C:/snatcher/lua/SUB/0.4.45.lua')

local function readByte(address, kind)
  local ok, value = pcall(emu.read, address, kind)
  if not ok or type(value) ~= 'number' then return 0 end
  return value
end

local function writeZero(address, kind)
  local ok = pcall(emu.write, address, 0, kind)
  return ok
end

local function pointsAtSelected(pattern, attr)
  -- 자막 엔트리는 palette F다. 이 조건 없이 주소만 보면 나중에 같은 블록을
  -- 가져간 게임 스프라이트까지 지울 수 있다.
  if (attr & 0x0F) ~= 0x0F then return false end

  local first = (pattern & 0x07FF) << 5
  local width = ((attr & 0x0100) ~= 0) and 2 or 1
  local hcode = (attr >> 12) & 0x03
  local height = (hcode == 0) and 1 or ((hcode == 1) and 2 or 4)
  local last = first + width * height * 0x40 - 1

  for base in pairs(selected) do
    if last >= base and first < base + BLOCK_WORDS then return true end
  end
  return false
end

local function wipeTable(kind, origin)
  if not kind then return 0, false end
  local wiped, writable = 0, true
  for slot = 0, 63 do
    local at = origin + slot * 8
    local pattern = readByte(at + 4, kind) | (readByte(at + 5, kind) << 8)
    local attr    = readByte(at + 6, kind) | (readByte(at + 7, kind) << 8)
    if pointsAtSelected(pattern, attr) then
      for byte = 0, 7 do
        if not writeZero(at + byte, kind) then writable = false end
      end
      wiped = wiped + 1
    end
  end
  return wiped, writable
end

local previousState = readByte(STATE, MEM)
local wipes, vramSlots, spriteSlots = 0, 0, 0

emu.addEventCallback(function()
  local state = readByte(STATE, MEM)
  local ended = previousState ~= 0 and state == 0 and selectedCount > 0
  previousState = state
  if not ended then return end

  local v, vOK = wipeTable(VRAM, SATB)
  local s, sOK = wipeTable(SPR, 0)
  wipes, vramSlots, spriteSlots = wipes + 1, vramSlots + v, spriteSlots + s

  realLog(string.format(
    'SUB %s ★ WIPE #%d: VRAM SATB %d칸 · Sprite RAM %d칸%s%s',
    VERSION, wipes, v, s,
    vOK and '' or ' · VRAM write fail',
    sOK and '' or ' · Sprite RAM write fail'))

  -- 다음 음성에서는 새로 선택되는 블록만 대상으로 삼는다.
  selected, selectedCount = {}, 0
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  emu.drawString(4, 44, string.format('0.4.47 WIPE %d  V%d S%d',
                 wipes, vramSlots, spriteSlots), 0x80FF80, 0x000000)
end, emu.eventType.endFrame)

realLog('SUB ' .. VERSION .. ' loaded -- subtitle-end SATB/Sprite RAM wipe')
realLog('  자막 패턴 VRAM은 유지 · 자막 표시 슬롯만 종료 순간 0으로 지움')
realLog('  Power Cycle 뒤 이 파일 하나만 실행')
