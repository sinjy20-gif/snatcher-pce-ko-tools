-- SUB 0.4.93-hq-key-vram -- 본부에서 수집한 음성별 안전 VRAM 표 연결판.
--
-- 이번 판은 각 key의 A base만 쓴다. 목적은 렌더러, helper save/restore,
-- fragment wipe가 같은 동적 주소를 끝까지 따라가는지 확인하는 것이다.
-- 표의 B base 핑퐁은 두 번째 백업 슬롯을 추가한 뒤 별도 판에서 연다.

local MEM = emu.memType.pceMemory
local AC = emu.memType.pceArcadeCardRam
local ENGINE_CPU, ENGINE_AC, HELPER_AC = 0x5B80, 0x1F1F00, 0x1F1C00
local HELPER_CTL = 432

local pairs = assert(dofile('C:/snatcher/build/cutscene_subs/vram_key_bases_pairs.lua'),
                           'HQ key-base table missing')
local info = assert(dofile('C:/snatcher/build/cutscene_subs/engine_ac_lua_frame_rearm.lua'),
                    'rearm engine offset table missing')
local off = info.offsets
for _, need in ipairs({'vram_base_hi_imm', 'pattern_base_lo_imm', 'pattern_attr_imm'}) do
  assert(off[need], 'engine table missing ' .. need)
end

local selected, skipped = 0, 0
local function write(at, value, kind)
  emu.write(at, value & 0xFF, kind)
end

local function patchEngine(where, base, kind)
  -- engine generator deliberately requires $100-word alignment for this form.
  assert((base & 0xFF) == 0, string.format('key base $%04X is not $100 aligned', base))
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
  if rawget(_G, 'SUB_D000_ONLY') == true and key ~= '00D00E437790' then
    _G.SUB_D000_BLOCKED = (rawget(_G, 'SUB_D000_BLOCKED') or 0) + 1
    return false
  end
  local pair = pairs[key]
  if not pair then
    skipped = skipped + 1
    return false
  end
  local base = pair[1] -- A only: single-backup validation pass
  if phase == 'start' then
    setHelperBase(base)
    patchEngine(ENGINE_AC, base, AC)
  else
    patchEngine(ENGINE_CPU, base, MEM)
  end
  _G.SUB_VOICE_CURRENT_BASE = base
  if rawget(_G, 'SUB_D000_ONLY') == true then
    _G.SUB_D000_MATCHES = (rawget(_G, 'SUB_D000_MATCHES') or 0) + 1
  end
  selected = selected + 1
  emu.log(string.format('SUB 0.4.93 HQ %s %d -> $%04X', phase, part, base))
  return true
end

SUB_FRAGMENT_WIPE_VERSION = '0.4.93-hq-key-vram'
dofile('C:/snatcher/lua/SUB/0.4.89-vdc-rearm.lua')
SUB_FRAGMENT_WIPE_VERSION = nil

emu.addEventCallback(function()
  emu.drawString(4, 58, string.format('0.4.93 HQ key-base A:%d skip:%d', selected, skipped),
                 0x80D0FF, 0x000000)
end, emu.eventType.endFrame)
emu.log('SUB 0.4.93 HQ key-base armed -- 50 collected keys · A-base save/render/restore verification')
