-- SUB 0.5.109 -- 2026-08-30 국장실 ADPCM 동결 기준 재현 전용.
--
-- 실행 조합:
--   C:\snatcher\build\patch\0.4.6.22-dictionary-key-vram\ 의 CUE/BIOS
--   Power Cycle 뒤 이 파일 하나만 로드
--
-- 현재 pack/base 표를 절대 쓰지 않는다.  동결 pack 8F20AF38, 당시 653 B
-- rearm 엔진, 당시 12-hex 50-key A-base 표를 한 세트로 묶는다.
-- 이 파일은 현행 전체화용이 아니며, 국장실 기준 동작을 되찾아 비교하는 용도다.

local MEM = emu.memType.pceMemory
local AC = emu.memType.pceArcadeCardRam
local ENGINE_CPU, ENGINE_AC, HELPER_AC = 0x5B80, 0x1F1F00, 0x1F1C00
local HELPER_CTL = 432

local ROOT = 'C:/snatcher'
local PAIRS_PATH = ROOT .. '/_archive/20260902_before_pairs_regen/vram_key_bases_pairs.lua'
local INFO_PATH = ROOT .. '/build/cutscene_subs/engine_ac_lua_frame_rearm_frozen_8F20AF38_6600.lua'
local PACK_PATH = ROOT .. '/build/cutscene_subs/subtitle_pack.frozen_8F20AF38.bin'

local pairs = assert(dofile(PAIRS_PATH), '0.5.109: frozen 50-key table missing')
local info = assert(dofile(INFO_PATH), '0.5.109: frozen renderer table missing')
local off = info.offsets
for _, need in ipairs({'vram_base_hi_imm', 'pattern_base_lo_imm', 'pattern_attr_imm'}) do
  assert(off[need], '0.5.109: renderer offset missing ' .. need)
end

local selected, skipped = 0, 0
local function write(at, value, kind)
  emu.write(at, value & 0xFF, kind)
end

local function patchEngine(where, base, kind)
  assert((base & 0xFF) == 0, string.format('0.5.109: base $%04X not $100 aligned', base))
  write(where + off.vram_base_hi_imm, base >> 8, kind)
  write(where + off.pattern_base_lo_imm, ((base >> 6) << 1) & 0xFF, kind)
  write(where + off.pattern_attr_imm,
        0x80 | (((base >> 13) & 0x07) << 4) | 0x0F, kind)
end

local function setHelperBase(base)
  write(HELPER_AC + HELPER_CTL + 4, base, AC)
  write(HELPER_AC + HELPER_CTL + 5, base >> 8, AC)
  write(HELPER_AC + HELPER_CTL + 6, base >> 13, AC)
  write(HELPER_AC + HELPER_CTL + 7, base >> 5, AC)
end

_G.SUB_VOICE_SELECT_BASE = function(key, part, phase)
  local pair = pairs[key]
  if not pair then
    skipped = skipped + 1
    return false
  end
  local base = pair[1] -- 당시 0.4.93과 같은 A-base 단독 경로
  if phase == 'start' then
    setHelperBase(base)
    patchEngine(ENGINE_AC, base, AC)
  else
    patchEngine(ENGINE_CPU, base, MEM)
  end
  _G.SUB_VOICE_CURRENT_BASE = base
  selected = selected + 1
  emu.log(string.format('SUB 0.5.109 FROZEN %s %d -> $%04X', phase, part, base))
  return true
end

-- 0.4.89-controller -> 0.4.31가 이 세대의 엔진/팩을 읽게 한다.
_G.SUB_REARM_INFO_PATH = INFO_PATH
_G.SUB_VOICE_PACK_PATH = PACK_PATH
SUB_FRAGMENT_WIPE_VERSION = '0.5.109-frozen-baseline'
dofile(ROOT .. '/lua/SUB/0.4.89-vdc-rearm.lua')
SUB_FRAGMENT_WIPE_VERSION = nil
_G.SUB_REARM_INFO_PATH = nil
_G.SUB_VOICE_PACK_PATH = nil

emu.addEventCallback(function()
  emu.drawString(4, 58, string.format('0.5.109 frozen key-base A:%d skip:%d', selected, skipped),
                 0x80D0FF, 0x000000)
end, emu.eventType.endFrame)

emu.log('SUB 0.5.109 loaded -- 0.4.6.22 director-room frozen baseline')
emu.log('  pack 8F20AF38 · engine 653 B @ $6600 · old 12-hex 50-key A-base table')
emu.log('  current pack/table are not used; Power Cycle first, then load this file only')
