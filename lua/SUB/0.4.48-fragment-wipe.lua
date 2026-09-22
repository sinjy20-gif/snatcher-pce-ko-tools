-- SUB 0.4.48-fragment-wipe -- 조각 전환과 음성 종료 모두 자막 슬롯 와이프
--
-- 0.4.47은 음성 전체 종료 때만 지웠다. 여러 조각짜리 음성은 다음 조각의
-- PATCHED가 발생한 뒤에도 이전 조각 SATB가 한 프레임 남을 수 있다. 그 사이
-- 이전 VRAM 블록의 게임 패턴이 UI 조각처럼 비친다.
--
-- 이 판은
--   1) 새 조각 PATCHED 직전: 이전 조각 슬롯 와이프
--   2) 음성 종료: 마지막 조각 슬롯 와이프
-- 를 VRAM SATB와 VDC 내부 Sprite RAM 양쪽에 수행한다.

local VERSION = rawget(_G, 'SUB_FRAGMENT_WIPE_VERSION') or
                '0.4.48-fragment-wipe'
local CHILD = rawget(_G, 'SUB_FRAGMENT_WIPE_CHILD') or
              'C:/snatcher/lua/SUB/0.4.45.lua'
local MEM  = emu.memType.pceMemory
local VRAM = emu.memType.pceVideoRam
local SPR  = emu.memType.pceSpriteRam

local STATE       = 0x7FDF
local SATB        = 0x2000
local BLOCK_WORDS = 19 * 0x40
local ENGINE      = 0x5B80

-- 시험 wrapper가 지정하면 특정 음성의 모든 조각을 한 주소에 고정한다.
-- 0.4.45의 631 B 엔진 피연산자 위치다.
local FORCE_KEY  = rawget(_G, 'SUB_FRAGMENT_FORCE_KEY')
local FORCE_BASE = rawget(_G, 'SUB_FRAGMENT_FORCE_BASE')
if FORCE_BASE then FORCE_BASE = FORCE_BASE & 0xFFE0 end

local realLog = emu.log
local selected = {}
local selectedCount = 0
local wipeSelected
local forceRenderer
local forceVoice = false
local wipes, transitionWipes, endWipes = 0, 0, 0
local vramSlots, spriteSlots = 0, 0

-- allocator의 PATCHED 로그가 곧 새 조각의 VRAM 선택 시점이다. 새 주소를 대상에
-- 넣기 전에 이전 주소를 가리키는 슬롯을 지워야 새 자막까지 지우지 않는다.
emu.log = function(message)
  local text = tostring(message)
  local key = text:match('KEY #%d+ (%x+)')
  if key then forceVoice = FORCE_KEY ~= nil and key == FORCE_KEY end
  local hex = text:match('PATCHED base=%$(%x%x%x%x)')
  if hex then
    if selectedCount > 0 and wipeSelected then wipeSelected('FRAGMENT') end
    local base = tonumber(hex, 16)
    if forceVoice and FORCE_BASE and forceRenderer then
      base = FORCE_BASE
      forceRenderer(base)
      realLog(string.format('SUB %s ★ FORCE %s -> $%04X', VERSION, FORCE_KEY, base))
    end
    selected = { [base] = true }
    selectedCount = 1
  end
  realLog(text)
end

dofile(CHILD)

local function readByte(address, kind)
  local ok, value = pcall(emu.read, address, kind)
  if not ok or type(value) ~= 'number' then return 0 end
  return value
end

local function writeZero(address, kind)
  local ok = pcall(emu.write, address, 0, kind)
  return ok
end

forceRenderer = function(base)
  emu.write(ENGINE + 144, base & 0xFF, MEM)             -- VDC MAWR low
  emu.write(ENGINE + 146, (base >> 8) & 0xFF, MEM)      -- VDC MAWR high
  emu.write(ENGINE + 255, (base >> 5) & 0xFF, MEM)      -- SAT pattern low
  emu.write(ENGINE + 260,
            0x80 | (((base >> 13) & 0x07) << 4) | 0x0F, MEM)
end

local function pointsAtSelected(pattern, attr)
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

wipeSelected = function(reason)
  if selectedCount == 0 then return end
  local v, vOK = wipeTable(VRAM, SATB)
  local s, sOK = wipeTable(SPR, 0)
  wipes, vramSlots, spriteSlots = wipes + 1, vramSlots + v, spriteSlots + s
  if reason == 'FRAGMENT' then
    transitionWipes = transitionWipes + 1
  else
    endWipes = endWipes + 1
  end
  realLog(string.format(
    'SUB %s ★ %s WIPE #%d: VRAM SATB %d칸 · Sprite RAM %d칸%s%s',
    VERSION, reason, wipes, v, s,
    vOK and '' or ' · VRAM write fail',
    sOK and '' or ' · Sprite RAM write fail'))
end

local previousState = readByte(STATE, MEM)
emu.addEventCallback(function()
  local state = readByte(STATE, MEM)
  local ended = previousState ~= 0 and state == 0 and selectedCount > 0
  previousState = state
  if not ended then return end

  wipeSelected('END')
  selected, selectedCount = {}, 0
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  emu.drawString(4, 44, string.format('0.4.48 WIPE %d  F%d E%d  V%d S%d',
                 wipes, transitionWipes, endWipes, vramSlots, spriteSlots),
                 0x80FF80, 0x000000)
end, emu.eventType.endFrame)

realLog('SUB ' .. VERSION .. ' loaded -- fragment-transition + subtitle-end wipe')
realLog('  새 조각 직전에 이전 SATB/Sprite RAM 와이프 · 음성 종료에 마지막 조각 와이프')
realLog('  Power Cycle 뒤 이 파일 하나만 실행')
