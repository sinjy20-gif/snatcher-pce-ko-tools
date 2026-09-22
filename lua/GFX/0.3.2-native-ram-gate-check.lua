-- GFX 0.3.2 -- native r2의 RAM gate를 읽기만 해서 확인한다
--
-- ★ 순수 관측. VRAM/VDC/게임 RAM/AC에 아무것도 쓰지 않는다.
-- r2가 안 뜰 때 "업로더 코드가 달랐나 / 마지막 버퍼가 안 남았나"를 한 번에 가른다.

local MEM = emu.memType.pceMemory
local VRAM = emu.memType.pceVideoRam
local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH = 'C:/snatcher/dump/gfx_native_ram_gate_' .. STAMP .. '.tsv'
local out = assert(io.open(PATH, 'w'))
out:write('frame\tkind\tdetail\n')

local UPLOAD_AT = 0x725C
local UPLOAD = {
  0xBD,0x00,0x3B,0x8D,0x02,0x00,0xE8,0xBD,0x00,0x3B,
  0x8D,0x03,0x00,0xE8,0xE0,0x20,0x90,0xEE,0x60,
}
local BUFFER_AT = 0x3B00
local BUFFER = {
  0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
  0x30,0x00,0x48,0x00,0x48,0x00,0x30,0x00,
  0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
  0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
}
local VRAM_SIG_AT = 0x16A * 32
local VRAM_SIG = {0x80,0x00,0x40,0x00,0x20,0x00,0x10,0x00,
                  0x08,0x00,0x04,0x00,0x03,0x00,0xFC,0x00}

local function same(at, expected, mem)
  for i, value in ipairs(expected) do
    if emu.read(at + i - 1, mem, false) ~= value then return false end
  end
  return true
end

local function hex(at, count)
  local t = {}
  for i = 0, count - 1 do t[#t + 1] = ('%02X'):format(emu.read(at + i, MEM, false) or 0) end
  return table.concat(t, ' ')
end

local frame = 0
local code_seen, buffer_seen, vram_seen = false, false, false
local function hit(kind, detail)
  out:write(('%d\t%s\t%s\n'):format(frame, kind, detail)); out:flush()
  emu.log(('GFX gate f%d ★%s %s'):format(frame, kind, detail))
end

emu.addEventCallback(function()
  frame = frame + 1
  local code = same(UPLOAD_AT, UPLOAD, MEM)
  local buffer = same(BUFFER_AT, BUFFER, MEM)
  local vram = same(VRAM_SIG_AT, VRAM_SIG, VRAM)
  if code and not code_seen then code_seen = true; hit('UPLOAD_CODE', '$725C exact') end
  if buffer and not buffer_seen then buffer_seen = true; hit('BUFFER_18C', '$3B00 exact') end
  if vram and not vram_seen then vram_seen = true; hit('VRAM_DEDICATION', '$16A exact') end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if not code_seen then hit('MISS_UPLOAD_CODE', hex(UPLOAD_AT, #UPLOAD)) end
  if not buffer_seen then hit('MISS_BUFFER_18C', hex(BUFFER_AT, #BUFFER)) end
  out:close()
  emu.log('GFX gate log: ' .. PATH)
end, emu.eventType.scriptEnded)

emu.log('GFX 0.3.2 native RAM gate check -- read only')
emu.log('  ' .. PATH)
