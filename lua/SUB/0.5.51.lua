-- SUB 0.5.51 -- native armer 공통 정적 AC 로더
-- 런타임 callback 없음. key/selector/state 판단은 BIOS만 수행한다.

local AC = emu.memType.pceArcadeCardRam
local PACK_AT = 0x1C0000
local ENGINE_AT = 0x1F1F00
local ENGINE_TEMPLATE_AT = 0x1FC900
local HELPER_AT = 0x1F1C00
local SLOT_AT = 0x1F2700
local DIR_AT = 0x1F2800
local PAYLOAD_AT = 0x1F3D24
local MASTER_AT = 0x1FA400
local D000_BASE = 0x6600

local function read(path)
  local f = assert(io.open(path, 'rb'), 'cannot open ' .. path)
  local data = f:read('*a'); f:close(); return data
end

local function upload(at, data)
  for i = 1, #data do emu.write(at + i - 1, data:byte(i), AC) end
end

local pack = read('C:/snatcher/build/cutscene_subs/subtitle_pack.bin')
local engine = read('C:/snatcher/build/cutscene_subs/engine_ac_lua_frame_rearm.bin')
local directory = read('C:/snatcher/build/cutscene_subs/adpcm_native_subtitle_dir.bin')
local payload = read('C:/snatcher/build/cutscene_subs/adpcm_native_subtitle_payload.bin')
local master = read('C:/snatcher/build/cutscene_subs/adpcm_lba_master_index.bin')
local info = assert(dofile('C:/snatcher/build/cutscene_subs/engine_ac_lua_frame_rearm.lua'))

upload(PACK_AT, pack)
upload(ENGINE_AT, engine)
upload(ENGINE_TEMPLATE_AT, engine)
upload(DIR_AT, directory)
upload(PAYLOAD_AT, payload)
upload(MASTER_AT, master)

-- D000에서 검증된 고정 base $6600. 런타임 선택이 아니라 로드 시 1회 패치다.
local off = info.offsets
for _, at in ipairs({ENGINE_AT, ENGINE_TEMPLATE_AT}) do
  emu.write(at + off.vram_base_hi_imm, D000_BASE >> 8, AC)
  emu.write(at + off.pattern_base_lo_imm, ((D000_BASE >> 6) << 1) & 0xFF, AC)
  emu.write(at + off.pattern_attr_imm,
    0x80 | (((D000_BASE >> 13) & 7) << 4) | 0x0F, AC)
end

-- 선적재된 helper control block도 같은 base로 맞춘다.
local ctl = HELPER_AT + 432
emu.write(ctl + 4, D000_BASE & 0xFF, AC)
emu.write(ctl + 5, (D000_BASE >> 8) & 0xFF, AC)
emu.write(ctl + 6, (D000_BASE >> 13) & 0xFF, AC)
emu.write(ctl + 7, (D000_BASE >> 5) & 0xFF, AC)
for i = 0, 12 do emu.write(SLOT_AT + i, 0, AC) end

emu.log('SUB 0.5.51 static loader complete')
emu.log(string.format('  pack %d · engine %d · dir %d · payload %d · master %d B',
  #pack, #engine, #directory, #payload, #master))
emu.log('  D000 base $6600 · runtime callbacks 0 · native armer test BIOS required')
emu.log(string.format('  safe engine template %d B @ $%06X', #engine, ENGINE_TEMPLATE_AT))
emu.log('  native target: LBA $003083 -> mini index + first selector + state 1')
