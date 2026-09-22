-- SUB 0.4.29 -- no-subtitle BIOS + Lua-only ALLVOICE $1600 test.
--
-- Clean baseline:
--   Syscard3_galmuri_0.4.6.11_no_subtitle_diag.pce changes the native gate's
--   first branch at mapped $FEC7 (BIOS file/PRG offset $001EDA) from BNE to
--   BRA, so no subtitle can begin by itself.
--
-- This wrapper temporarily restores that one opcode to BNE, then loads the
-- already-proven 0.4.27 path:
--   * actual ADPCM detection and one trigger per real playback
--   * the same E6800_0E two-fragment dummy subtitle on every rate-$0E voice
--   * helper/renderer fixed to VRAM $1600-$1ABF
--   * Lua snapshot/restore of the selected VRAM block
--
-- Load AFTER Power Cycle with the no-subtitle diagnostic BIOS.  Do not load
-- 0.4.27 separately; this file loads it itself.

local MEM = emu.memType.pceMemory
local ROM = emu.memType.pcePrgRom
local MAPPED_BRANCH = 0xFEC7
local ROM_BRANCH = 0x001EDA
local BLOCKED, ENABLED = 0x80, 0xD0 -- BRA idle / BNE idle

local mappedBefore = emu.read(MAPPED_BRANCH, MEM) or -1
local romBefore = emu.read(ROM_BRANCH, ROM) or -1
local patchedMapped, patchedRom = false, false

local function hex(value)
  return value >= 0 and string.format('$%02X', value) or 'unreadable'
end

if mappedBefore ~= BLOCKED and romBefore ~= BLOCKED then
  error(string.format(
    'SUB 0.4.29 requires the no-subtitle diagnostic BIOS: mapped $FEC7=%s, PRG[$001EDA]=%s',
    hex(mappedBefore), hex(romBefore)))
end

-- Prefer the CPU-mapped byte because it is the code the HuC6280 executes.
if mappedBefore == BLOCKED then
  emu.write(MAPPED_BRANCH, ENABLED, MEM)
  patchedMapped = true
end

-- Some Mesen builds reject writes through the mapped ROM view.  Fall back to
-- the underlying PRG-ROM offset used by make_no_subtitle_bios.py.
local mappedAfter = emu.read(MAPPED_BRANCH, MEM) or -1
if mappedAfter ~= ENABLED and romBefore == BLOCKED then
  emu.write(ROM_BRANCH, ENABLED, ROM)
  patchedRom = true
  mappedAfter = emu.read(MAPPED_BRANCH, MEM) or -1
end

if mappedAfter ~= ENABLED then
  error(string.format(
    'SUB 0.4.29 no-sub gate unlock failed: mapped %s->%s, PRG %s. ' ..
    'Power Cycle with Syscard3_galmuri_0.4.6.11_no_subtitle_diag.pce, then load this Lua.',
    hex(mappedBefore), hex(mappedAfter), hex(romBefore)))
end

emu.log(string.format(
  'SUB 0.4.29 ★ NO-SUB GATE UNLOCKED: mapped $FEC7 %s->$D0 · PRG[$001EDA]=%s',
  hex(mappedBefore), hex(emu.read(ROM_BRANCH, ROM) or -1)))
emu.log('  이제부터 원래 자막은 0회 · Lua가 승인한 실제 음성만 자막 시작')

-- Register cleanup before loading the child scripts.  Stopping this wrapper
-- restores the diagnostic BIOS behavior for the remainder of the session.
emu.addEventCallback(function()
  if patchedMapped then emu.write(MAPPED_BRANCH, BLOCKED, MEM) end
  if patchedRom then emu.write(ROM_BRANCH, BLOCKED, ROM) end
  emu.log('SUB 0.4.29 no-sub gate restored to BRA idle')
end, emu.eventType.scriptEnded)

dofile('C:/snatcher/lua/SUB/0.4.27.lua')

emu.addEventCallback(function()
  emu.drawString(4, 44, '0.4.29 NO-SUB + LUA ONLY', 0x40FF40, 0x000000)
end, emu.eventType.endFrame)

emu.log('SUB 0.4.29 loaded -- clean no-sub BIOS + Lua-only ALLVOICE $1600')
emu.log('  0.4.27을 따로 켜지 말 것 · 이 파일 하나만 실행')
