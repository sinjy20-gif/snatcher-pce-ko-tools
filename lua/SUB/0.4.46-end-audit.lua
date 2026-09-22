-- SUB 0.4.46-end-audit -- 자막 종료 UI 패턴 노출 원인 측정
--
-- 목적:
--   자막 종료 때 UI 선택 그림처럼 보이는 한 프레임/잔상이
--     A) VRAM 원본 복원이 너무 빠른 것인지
--     B) VRAM SATB 와 VDC 내부 Sprite RAM 의 갱신 시차인지
--     C) 자막 슬롯 자체가 끝까지 남는 것인지
--   구분한다.
--
-- 사용:
--   1. Power Cycle
--   2. 다른 SUB Lua는 전부 끈다.
--   3. 이 파일 하나만 Run한다. (내부에서 0.4.45를 적재한다.)
--   4. 문제가 보이는 자막이 끝날 때까지 진행한다.
--   5. 현상을 본 뒤 2~3초 기다리고 Stop한다.
--
-- 기록:
--   state $7FDF가 nonzero -> 0으로 내려가는 순간을 자막 종료로 잡는다.
--   종료 전 16프레임과 종료 후 90프레임 동안 아래 두 표를 모두 덤프한다.
--     * VRAM SATB       byte $2000, CPU가 갱신하는 표
--     * Sprite RAM      VDC 내부 사본, 실제 화면이 그리는 표
--   palette F, 자막 Y 부근, 또는 최근 자막 VRAM 블록과 겹치는 슬롯만 기록한다.
--   allocator의 PATCHED/restore 로그도 같은 TSV의 event 열에 합친다.

local VERSION = '0.4.46-end-audit'
local MEM  = emu.memType.pceMemory
local VRAM = emu.memType.pceVideoRam
local SPR  = emu.memType.pceSpriteRam
local STATE = 0x7FDF
local BLOCK_WORDS = 19 * 0x40
local PRE_FRAMES, POST_FRAMES = 16, 90

local stamp = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/sub_0_4_46_end_audit_' .. stamp .. '.tsv'
local out = assert(io.open(OUT, 'w'))
out:write('run\tframe\trel\tstate\tbase\tevent\tsource\tslot\t' ..
          'raw_y\ty\traw_x\tx\tpattern_word\tpattern_base\tattr\tpalette\t' ..
          'width\theight\tvisible\toverlaps_base\n')
out:flush()

local originalLog = emu.log
local frame, run = 0, 0
local currentBase, lastPatchFrame = nil, -100000
local queuedEvents = {}

local function queueEvent(text)
  queuedEvents[#queuedEvents + 1] = text:gsub('[\t\r\n]+', ' ')
end

-- 0.3.43-defer는 dofile 중 emu.log를 다시 감싼다. 그 안쪽 realLog가 이
-- wrapper가 되므로 allocator의 PATCHED/restore 문장도 여기까지 도착한다.
emu.log = function(msg)
  local text = tostring(msg)
  local hex = text:match('PATCHED base=%$(%x%x%x%x)')
  if hex then
    currentBase = tonumber(hex, 16)
    lastPatchFrame = frame
    queueEvent('PATCH ' .. hex)
  end
  local restored = text:match('restore %$(%x%x%x%x)')
  if restored then queueEvent('RESTORE ' .. restored) end
  if text:find('게임이 가져갔다', 1, true) then queueEvent('TAKEN') end
  originalLog(text)
end

-- 실제 자막 스택. 이 파일만 실행해야 한다.
dofile('C:/snatcher/lua/SUB/0.4.45.lua')

local function readByte(address, kind)
  local ok, value = pcall(emu.read, address, kind)
  if not ok or type(value) ~= 'number' then return nil end
  return value
end

local spriteRamOK = false
if SPR then
  spriteRamOK = readByte(0, SPR) ~= nil
end

local function overlapsBase(first, words, base)
  if not base then return false end
  return first + words - 1 >= base and first < base + BLOCK_WORDS
end

local function scan(source, kind, origin, base)
  local rows = {}
  for slot = 0, 63 do
    local at = origin + slot * 8
    local b = {}
    local readable = true
    for i = 0, 7 do
      b[i] = readByte(at + i, kind)
      if b[i] == nil then readable = false; break end
    end
    if readable then
      local rawY = b[0] | (b[1] << 8)
      local rawX = b[2] | (b[3] << 8)
      local pat  = b[4] | (b[5] << 8)
      local attr = b[6] | (b[7] << 8)
      local y, x = (rawY & 0x03FF) - 64, (rawX & 0x03FF) - 32
      local width = ((attr & 0x0100) ~= 0) and 32 or 16
      local hcode = (attr >> 12) & 0x03
      local height = (hcode == 0) and 16 or ((hcode == 1) and 32 or 64)
      local widthCells, heightCells = width // 16, height // 16
      local first = (pat & 0x07FF) << 5
      local words = widthCells * heightCells * 0x40
      local palette = attr & 0x0F
      local visible = x < 256 and y < 224 and x + width > 0 and y + height > 0
      local overlap = overlapsBase(first, words, base)
      local relevant = palette == 0x0F or (y >= 110 and y <= 145) or overlap
      if relevant then
        rows[#rows + 1] = {
          source=source, slot=slot, rawY=rawY, y=y, rawX=rawX, x=x,
          pat=pat, first=first, attr=attr, palette=palette,
          width=width, height=height, visible=visible and 1 or 0,
          overlap=overlap and 1 or 0,
        }
      end
    end
  end
  return rows
end

local function statePC()
  local ok, s = pcall(emu.getState)
  if not ok or not s then return 0 end
  return s['cpu.pc'] or 0
end

local function snapshot()
  local state = readByte(STATE, MEM) or 0
  local events = table.concat(queuedEvents, ';')
  queuedEvents = {}
  local snap = {
    frame=frame, state=state, base=currentBase, event=events, pc=statePC(), rows={}
  }
  local a = scan('VRAM_SATB', VRAM, 0x2000, currentBase)
  for _, row in ipairs(a) do snap.rows[#snap.rows + 1] = row end
  if spriteRamOK then
    local b = scan('SPRITE_RAM', SPR, 0, currentBase)
    for _, row in ipairs(b) do snap.rows[#snap.rows + 1] = row end
  end
  return snap
end

local ring, previousState = {}, readByte(STATE, MEM) or 0
local activeRun, endFrame, postLeft = false, nil, 0
local written = {}

local function writeSnapshot(snap, rel, eventExtra)
  local key = string.format('%d:%d', run, snap.frame)
  if written[key] then return end
  written[key] = true
  local event = snap.event
  if eventExtra and eventExtra ~= '' then
    event = (event ~= '' and (event .. ';') or '') .. eventExtra
  end
  if #snap.rows == 0 then
    out:write(string.format('%d\t%d\t%d\t%02X\t%s\t%s\tMETA\t-1\t' ..
      '0\t0\t0\t0\t0000\t0000\t0000\t0\t0\t0\t0\t0\n',
      run, snap.frame, rel, snap.state,
      snap.base and string.format('%04X', snap.base) or '', event))
  else
    for _, r in ipairs(snap.rows) do
      out:write(string.format(
        '%d\t%d\t%d\t%02X\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%04X\t%04X\t%04X\t%X\t%d\t%d\t%d\t%d\n',
        run, snap.frame, rel, snap.state,
        snap.base and string.format('%04X', snap.base) or '', event,
        r.source, r.slot, r.rawY, r.y, r.rawX, r.x, r.pat, r.first,
        r.attr, r.palette, r.width, r.height, r.visible, r.overlap))
    end
  end
  out:flush()
end

emu.addEventCallback(function()
  frame = frame + 1
  local snap = snapshot()
  ring[#ring + 1] = snap
  while #ring > PRE_FRAMES do table.remove(ring, 1) end

  local ended = previousState ~= 0 and snap.state == 0 and
                (frame - lastPatchFrame) < 1200
  previousState = snap.state

  if ended then
    run = run + 1
    activeRun, endFrame, postLeft = true, frame, POST_FRAMES
    for _, old in ipairs(ring) do
      writeSnapshot(old, old.frame - endFrame,
                    old.frame == endFrame and 'STATE_FALL' or '')
    end
    originalLog(string.format(
      'SUB %s ★ END #%d f=%d base=$%s · 종료 전 %d/후 %d프레임 기록',
      VERSION, run, frame, currentBase and string.format('%04X', currentBase) or '----',
      PRE_FRAMES, POST_FRAMES))
  elseif activeRun then
    writeSnapshot(snap, frame - endFrame, '')
  end

  if activeRun then
    postLeft = postLeft - 1
    if postLeft <= 0 then
      activeRun = false
      originalLog(string.format('SUB %s END #%d capture complete: %s', VERSION, run, OUT))
    end
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:close()
  originalLog(string.format('SUB %s saved: %s', VERSION, OUT))
end, emu.eventType.scriptEnded)

originalLog(string.format('SUB %s loaded -- 0.4.45 + subtitle-end SATB audit', VERSION))
originalLog('  Power Cycle 뒤 이 파일만 실행 · 자막 종료 한 번 보고 2~3초 후 Stop')
originalLog(string.format('  Sprite RAM readable: %s · output: %s', tostring(spriteRamOK), OUT))
