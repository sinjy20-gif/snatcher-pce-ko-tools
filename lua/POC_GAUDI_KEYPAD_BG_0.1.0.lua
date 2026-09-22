-- POC_GAUDI_KEYPAD_BG 0.1.0
-- 현재 가우디 자판 화면의 BG 글자 타일 45개를 완성형 한글 6x6로 바꾼다.
-- 디스크는 수정하지 않으며, 원본 덤프와 목표 VRAM의 차이 바이트만 쓴다.

local BASE = "C:\\snatcher\\dump\\gaudi_keypad_vram_v010.bin"
local TARGET = "C:\\snatcher\\build\\gfx\\gaudi_keypad\\gaudi_keypad_hangul_vram.bin"
local VRAM = emu.memType.pceVideoRam

local function readAll(path)
  local f = assert(io.open(path, "rb"))
  local data = f:read("*a")
  f:close()
  return data
end

local base = readAll(BASE)
local target = readAll(TARGET)
assert(#base == 0x10000 and #target == 0x10000, "VRAM payload size mismatch")

-- Active left keypad BAT signature: rows 17-19, palette E panel.
local signatures = {
  { (17 * 128 + 4) * 2, { 0x12 }, 0xE2 },
  -- The first POC run splits this shared tile from $226 to spare tile $27F.
  -- Accept both values so a revised glyph payload can be applied in place.
  { (18 * 128 + 4) * 2, { 0x26, 0x7F }, 0xE2 },
  { (19 * 128 + 4) * 2, { 0x3A }, 0xE2 },
}
for _, s in ipairs(signatures) do
  local lo = emu.read(s[1], VRAM) or 0
  local hi = emu.read(s[1] + 1, VRAM) or 0
  local lo_ok = false
  for _, expected_lo in ipairs(s[2]) do
    if lo == expected_lo then lo_ok = true end
  end
  assert(lo_ok and hi == s[3],
    string.format("keypad BAT signature mismatch at $%04X: %02X %02X", s[1], lo, hi))
end

local writes = 0
for address = 0, 0xFFFF do
  local before = string.byte(base, address + 1)
  local after = string.byte(target, address + 1)
  if before ~= after then
    emu.write(address, after, VRAM)
    writes = writes + 1
  end
end

emu.log(string.format("POC GAUDI KEYPAD BG 0.1.0 -- %d changed VRAM bytes written", writes))
emu.log("아래 자판의 한글 45칸과 테두리를 확인한 뒤 스크린샷 -> Stop")
