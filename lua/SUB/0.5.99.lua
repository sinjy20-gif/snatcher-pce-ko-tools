-- SUB 0.5.99 -- 0.5.98 + 중간 스킵은 sprite wipe만 하고 VRAM 복원 생략
--
-- 0.5.98이 확정한 것:
--   audio stop -> state 3 -> helper restore가 1프레임 안에 정확히 실행된다.
--   그런데 시작 시점 VRAM 백업을 되쓰면 여전히 화면이 깨진다.
--
-- 따라서 중간 스킵 helper에서:
--   JSR wipe_sprites       그대로 실행
--   VRAM restore body      건너뜀
--   helper status tail     그대로 실행
--
-- 정상 종료는 0.5.98/0.5.77의 최신 화면 refresh를 그대로 사용한다.
-- ADPCM은 건드리지 않는다. Power Cycle 뒤 이 파일 하나만 로드한다.

dofile('C:/snatcher/lua/SUB/0.5.98.lua')

local VERSION = '0.5.99'
local TAG = 'SUB ' .. VERSION
local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local ENTRY = 0x5B83
local ENTRY_SIG = { 0xAD, 0x30, 0x5D, 0xD0 }
local CTL_CMD, CTL_LO, CTL_HI = 0x5D30, 0x5D34, 0x5D35
local ELAPSED = 0x5E1D
local CDDA_BASE = 0x7900
local FINISH_AT = 2683

-- 0.4.6.48 helper layout. +$06C JSR wipe_sprites 뒤 +$06F가 복원 본체다.
local RESTORE_SITE = 0x5B80 + 0x06F
local RESTORE_ORIG = { 0xA9, 0x00, 0x8D }          -- LDA #0 / STA ...
local RESTORE_SKIP = { 0x4C, 0x37, 0x5C }          -- JMP $5C37 status tail

local frame, bypassed, refused = 0, 0, 0

local function rb(at)
  return emu.read(at, MEM) or 0
end

local function elapsed()
  return rb(ELAPSED) | (rb(ELAPSED + 1) << 8)
end

local function helperBase()
  return rb(CTL_LO) | (rb(CTL_HI) << 8)
end

local function isHelper()
  for i = 1, #ENTRY_SIG do
    if rb(ENTRY + i - 1) ~= ENTRY_SIG[i] then return false end
  end
  return true
end

local function bytesAre(want)
  for i = 1, #want do
    if rb(RESTORE_SITE + i - 1) ~= want[i] then return false end
  end
  return true
end

-- 0.5.98 callback 다음에 등록된다. 0.5.98이 조기 복원을 판정한 helper 진입에서
-- elapsed가 정상 종료값보다 작을 때만 현재 CPU helper의 복원 본체를 우회한다.
emu.addMemoryCallback(function()
  if not isHelper() or rb(CTL_CMD) == 0 then return end
  if helperBase() ~= CDDA_BASE or elapsed() >= FINISH_AT then return end

  if not bytesAre(RESTORE_ORIG) then
    refused = refused + 1
    if refused <= 3 then
      emu.log(string.format(
        '%s ★ REFUSE f%d site $%04X = %02X %02X %02X (expected A9 00 8D)',
        TAG, frame, RESTORE_SITE, rb(RESTORE_SITE), rb(RESTORE_SITE + 1),
        rb(RESTORE_SITE + 2)))
    end
    return
  end

  for i = 1, #RESTORE_SKIP do
    emu.write(RESTORE_SITE + i - 1, RESTORE_SKIP[i], MEM)
  end
  bypassed = bypassed + 1
  emu.log(string.format(
    '%s ★ EARLY WIPE-ONLY #%d f%d elapsed=%d · sprite wipe 후 VRAM 복원 생략',
    TAG, bypassed, frame, elapsed()))
end, emu.callbackType.exec, ENTRY, ENTRY, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  emu.log(string.format('%s END wipe-only=%d refused=%d', TAG, bypassed, refused))
end, emu.eventType.scriptEnded)

emu.log(TAG .. ' loaded -- 0.5.98 lifecycle + early skip sprite-wipe-only')
emu.log('  중간 스킵: state 3 -> wipe_sprites -> VRAM restore 생략 -> status tail')
emu.log('  정상 종료: 0.5.77 refresh 유지 · ADPCM 무개입')
