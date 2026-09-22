-- DUMP_GAUDI_KEYPAD_VRAM 0.1.0
-- 가우디 인명 검색 자판 화면의 VRAM 64KB와 CRAM 512B를 즉시 1회 저장한다.
-- 읽기 전용. 자판 화면이 완전히 보일 때 실행하고 완료 로그 뒤 Stop한다.

local VRAM = emu.memType.pceVideoRam
local CRAM = emu.memType.pcePaletteRam
local OUT_V = "C:\\snatcher\\dump\\gaudi_keypad_vram_v010.bin"
local OUT_C = "C:\\snatcher\\dump\\gaudi_keypad_cram_v010.bin"
local OUT_M = "C:\\snatcher\\dump\\gaudi_keypad_vram_v010.txt"

local function dump(path, memType, count)
  local bulk = nil
  if emu.getMemoryState ~= nil then
    local ok, value = pcall(emu.getMemoryState, memType)
    if ok and type(value) == "table" and #value >= count then bulk = value end
  end
  local f = assert(io.open(path, "wb"))
  for first = 0, count - 1, 4096 do
    local last = math.min(count - 1, first + 4095)
    local part = {}
    for a = first, last do
      local value = bulk and bulk[a + 1] or emu.read(a, memType)
      part[#part + 1] = string.char((value or 0) % 256)
    end
    f:write(table.concat(part))
  end
  f:close()
end

dump(OUT_V, VRAM, 0x10000)
dump(OUT_C, CRAM, 0x0200)

local meta = assert(io.open(OUT_M, "w"))
meta:write("screen\tgaudi_name_search_keypad\n")
meta:write("vram\t" .. OUT_V .. "\n")
meta:write("cram\t" .. OUT_C .. "\n")
meta:write("note\tread_only_single_capture\n")
meta:close()

emu.log("GAUDI KEYPAD VRAM dump complete -- Stop script")
emu.log("VRAM: " .. OUT_V)
emu.log("CRAM: " .. OUT_C)
