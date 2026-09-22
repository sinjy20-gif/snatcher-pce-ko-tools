-- SUB 0.4.54-ac-upload-only -- AC 팩/엔진 업로드만 분리한 기준시험
--
-- 하는 일: subtitle_pack.bin과 631 B Lua 엔진을 AC RAM에 한 번 쓴다.
-- 하지 않는 일: 음성 키 판정, CPU/RAM/VRAM/Sprite RAM write, controller,
--               allocator, wipe, memory callback, frame callback.
-- Power Cycle 뒤 다른 SUB Lua 없이 이 파일 하나만 실행할 것.

local VERSION = '0.4.54-ac-upload-only'
local AC = emu.memType.pceArcadeCardRam
local PACK_AT, ENGINE_AT = 0x1C0000, 0x1F1F00
local PACK_PATH = 'C:/snatcher/build/cutscene_subs/subtitle_pack.bin'
local ENGINE_PATH = 'C:/snatcher/build/cutscene_subs/engine_ac_lua_frame_mini.bin'

local function readFile(path)
  local f = assert(io.open(path, 'rb'), 'cannot open ' .. path)
  local data = f:read('*a'); f:close(); return data
end

local function putAndCount(at, data)
  local changed = 0
  for i = 1, #data do
    local value = data:byte(i)
    if (emu.read(at + i - 1, AC) or -1) ~= value then changed = changed + 1 end
    emu.write(at + i - 1, value, AC)
  end
  return changed
end

local pack, engine = readFile(PACK_PATH), readFile(ENGINE_PATH)
assert(pack:sub(1, 4) == 'SNSB', 'subtitle pack magic mismatch')
assert(#pack == 183918, 'unexpected pack size: ' .. #pack)
assert(#engine == 631, 'unexpected engine size: ' .. #engine)

local packChanged = putAndCount(PACK_AT, pack)
local engineChanged = putAndCount(ENGINE_AT, engine)

emu.log('SUB ' .. VERSION .. ' loaded -- AC UPLOAD ONLY')
emu.log(string.format('  pack   %d B -> $%06X · changed %d B',
                      #pack, PACK_AT, packChanged))
emu.log(string.format('  engine %d B -> $%06X · changed %d B',
                      #engine, ENGINE_AT, engineChanged))
emu.log('  callback 0 · CPU/RAM/VRAM/Sprite RAM write 0 B')
emu.log('  자막이 안 나오는 것이 정상 · 접수처 진행 여부만 확인')
