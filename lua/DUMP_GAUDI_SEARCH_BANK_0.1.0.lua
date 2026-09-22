-- DUMP_GAUDI_SEARCH_BANK 0.1.0
-- 가우디 검색 화면에서 MPR5=$7D일 때 CPU $A000-$BFFF의 실행 코드를 1회 덤프한다.
-- 조작이나 검색은 필요 없다. 파일 생성 로그가 뜨면 바로 Stop한다.

local OUT_BIN = "C:\\snatcher\\dump\\gaudi_search_bank7d_a000_bfff.bin"
local OUT_TXT = "C:\\snatcher\\dump\\gaudi_search_bank7d_a000_bfff.txt"
local MEM = emu.memType.pceMemory
local done = false

local function state()
  local ok, s = pcall(emu.getState)
  if ok and s then return s end
  return nil
end

local function mpr(s, slot)
  if not s then return 0 end
  return s[string.format("memoryManager.mpr[%d]", slot)]
      or s[string.format("mpr[%d]", slot)] or 0
end

local function dump()
  local parts = {}
  for a = 0xA000, 0xBFFF do
    parts[#parts + 1] = string.char(emu.read(a, MEM) or 0)
  end
  local data = table.concat(parts)
  local fb = assert(io.open(OUT_BIN, "wb")); fb:write(data); fb:close()

  local ft = assert(io.open(OUT_TXT, "w"))
  ft:write("MPR5=7D CPU=A000-BFFF size=2000\n")
  for a = 0xB9E0, 0xBA90, 16 do
    local row = {}
    for i = 0, 15 do row[#row + 1] = string.format("%02X", emu.read(a + i, MEM) or 0) end
    ft:write(string.format("%04X  %s\n", a, table.concat(row, " ")))
  end
  ft:close()
  done = true
  emu.log("GAUDI bank $7D dump complete -- Stop script")
  emu.log("output: " .. OUT_BIN)
end

emu.addEventCallback(function()
  if done then return end
  local s = state()
  if mpr(s, 5) == 0x7D then dump() end
end, emu.eventType.endFrame)

emu.log("DUMP_GAUDI_SEARCH_BANK 0.1.0 -- waiting for MPR5=$7D")
