-- SUB 0.5.61 -- 실기 정상 동결팩 8F20AF38용 native D000 정적 loader
-- BIOS 0.4.6.36 전용. runtime callback 없이 AC 데이터만 올린다.

local AC = emu.memType.pceArcadeCardRam
local PACK_AT, ENGINE_AT, TEMPLATE_AT = 0x1C0000, 0x1F1F00, 0x1FC900
local HELPER_AT, SLOT_AT = 0x1F1C00, 0x1F2700
local DIR_AT, PAYLOAD_AT, MASTER_AT = 0x1F2800, 0x1F3D24, 0x1FA400
local D000_BASE = 0x6600

local function read(path)
  local f = assert(io.open(path, 'rb'), 'cannot open ' .. path)
  local data = f:read('*a'); f:close(); return data
end

local function upload(at, data)
  for i = 1, #data do emu.write(at + i - 1, data:byte(i), AC) end
end

local pack = read('C:/snatcher/build/cutscene_subs/subtitle_pack.frozen_8F20AF38.bin')
local engine = read('C:/snatcher/build/cutscene_subs/engine_ac_lua_frame_rearm_frozen_8F20AF38.bin')
local directory = read('C:/snatcher/build/cutscene_subs/adpcm_native_subtitle_dir_frozen_8F20AF38.bin')
local payload = read('C:/snatcher/build/cutscene_subs/adpcm_native_subtitle_payload_frozen_8F20AF38.bin')
local master = read('C:/snatcher/build/cutscene_subs/adpcm_lba_master_index.bin')
local info = assert(dofile('C:/snatcher/build/cutscene_subs/engine_ac_lua_frame_rearm_frozen_8F20AF38.lua'))

assert(#pack == 183918, 'frozen pack size mismatch')
assert(#engine == 653 and #directory == 5412 and #payload == 26252,
       'frozen native artifact size mismatch')

upload(PACK_AT, pack)
upload(ENGINE_AT, engine)
upload(TEMPLATE_AT, engine)
upload(DIR_AT, directory)
upload(PAYLOAD_AT, payload)
upload(MASTER_AT, master)

-- D000의 실측 안전 A-base. active/template/helper를 반드시 같은 값으로 맞춘다.
local off = info.offsets
for _, at in ipairs({ENGINE_AT, TEMPLATE_AT}) do
  emu.write(at + off.vram_base_hi_imm, D000_BASE >> 8, AC)
  emu.write(at + off.pattern_base_lo_imm, ((D000_BASE >> 6) << 1) & 0xFF, AC)
  emu.write(at + off.pattern_attr_imm,
    0x80 | (((D000_BASE >> 13) & 7) << 4) | 0x0F, AC)
end

local ctl = HELPER_AT + 432
emu.write(ctl + 4, D000_BASE & 0xFF, AC)
emu.write(ctl + 5, (D000_BASE >> 8) & 0xFF, AC)
emu.write(ctl + 6, (D000_BASE >> 13) & 0xFF, AC)
emu.write(ctl + 7, (D000_BASE >> 5) & 0xFF, AC)
for i = 0, 12 do emu.write(SLOT_AT + i, 0, AC) end

emu.log('SUB 0.5.61 frozen baseline loader complete')
emu.log('  pack 8F20AF38 · 183918 B · matching 653 B engine/native table')
emu.log('  D000 base $6600 · runtime callbacks 0 · native armer BIOS required')
emu.log('  native target: LBA $003083 -> first selector + state 1')
