-- SNATCHER title menu sprite capture 0.7.2
--
-- 읽기 전용. 타이틀 메뉴가 보이는 상태에서 올리면 2초 뒤 다음을 dump/에 남긴다.
--   * 메뉴가 실제로 쓰는 VRAM 타일 7 블록
--   * VRAM SATB와 화면에 래치된 Sprite RAM 64 엔트리 (어느 블록이 어느 sprite인지)
--   * CRAM 전체 (원본 색을 그대로 재사용하기 위함)
--   * $725C 전송 루틴 호출 시점과 $3B00 32B 표본 (가능한 Mesen에서만)
--
-- Mesen: Script -> Settings -> Restrictions -> Allow I/O and OS 를 켠 뒤 올릴 것.
-- 게임 RAM/VRAM/CRAM에는 한 바이트도 쓰지 않는다.

local VRAM = emu.memType.pceVideoRam
local CRAM = emu.memType.pcePaletteRam
local SPR = emu.memType.pceSpriteRam
local CPU = emu.memType.pceMemory
local OUT = "C:/snatcher/dump"
local VERSION = "0.7.2"

-- VRAM word address, size in 16-bit words. Mesen pceVideoRam reads bytes.
local BLOCKS = {
  { id = "new_1",  word = 0x6700, words = 0x100, text = "처음부터: sprite 8, 32x32" },
  { id = "new_2",  word = 0x6800, words = 0x100, text = "처음부터: sprite 6, 32x32" },
  { id = "new_3",  word = 0x6E40, words = 0x080, text = "처음부터: sprite 5, 16x32" },
  { id = "save_1", word = 0x6900, words = 0x100, text = "세이브한 곳에서: sprite 7, 32x32" },
  { id = "save_2", word = 0x6A00, words = 0x100, text = "세이브한 곳에서: sprite 4, 32x32" },
  { id = "save_3", word = 0x6D00, words = 0x100, text = "세이브한 곳에서: sprite 3, 32x32" },
  { id = "save_4", word = 0x6680, words = 0x080, text = "세이브한 곳에서: sprite 2, 32x16" },
}

local frame, dumped = 0, false
local trace = {}
local stamp = os.date("%Y%m%d_%H%M%S")
local prefix = OUT .. "/title_menu_" .. stamp

local function byte(mem, addr) return emu.read(addr, mem) or 0 end
local function word(mem, addr)
  return byte(mem, addr) | (byte(mem, addr + 1) << 8)
end

local function write_binary(path, mem, start, count)
  local file = io.open(path, "wb")
  if file == nil then return false end
  local chunk = {}
  for offset = 0, count - 1 do
    chunk[#chunk + 1] = string.char(byte(mem, start + offset))
    if #chunk == 4096 then file:write(table.concat(chunk)); chunk = {} end
  end
  if #chunk > 0 then file:write(table.concat(chunk)) end
  file:close()
  return true
end

local function capture_725c()
  if #trace >= 256 then return end
  local sample = {}
  for offset = 0, 0x1F do sample[#sample + 1] = string.format("%02X", byte(CPU, 0x3B00 + offset)) end
  trace[#trace + 1] = { frame = frame, sample = table.concat(sample, " ") }
end

-- This is only a passive execution breakpoint. The title's bank mapping can differ
-- on other revisions, so absence of rows is diagnostic information, not a failure.
emu.addMemoryCallback(capture_725c, emu.callbackType.exec, 0x725C, 0x725C)

local function dump_sprite_table(path, mem, origin, source)
  local file = io.open(path, "w")
  if file == nil then return false end
  file:write("slot\ty_raw\tx_raw\tpattern_raw\tattr\tscreen_x\tscreen_y\tpattern_word\twidth\theight\tpalette\tpriority\tnote\n")
  local height = { [0] = 16, [1] = 32, [2] = 64, [3] = 64 }
  for slot = 0, 63 do
    local at = origin + slot * 8
    local y, x, pattern, attr = word(mem, at), word(mem, at + 2), word(mem, at + 4), word(mem, at + 6)
    if (y | x | pattern | attr) ~= 0 then
      local width = ((attr >> 8) & 1) == 1 and 32 or 16
      local h = height[(attr >> 12) & 3]
      local pat_word = (pattern >> 1) * 64
      local note = ""
      for _, block in ipairs(BLOCKS) do
        if pat_word == block.word then note = block.id .. " / " .. block.text end
      end
      file:write(string.format("%d\t%04X\t%04X\t%04X\t%04X\t%d\t%d\t%04X\t%d\t%d\t%d\t%s\t%s\n",
        slot, y, x, pattern, attr, x - 32, y - 64, pat_word, width, h,
        attr & 0x0F, ((attr & 0x80) ~= 0) and "front" or "back", note))
    end
  end
  file:close()
  return true
end

local function dump_trace(path)
  local file = io.open(path, "w")
  if file == nil then return false end
  file:write("frame\tpc\tbuffer_3b00_3b1f\n")
  for _, row in ipairs(trace) do
    file:write(string.format("%d\t725C\t%s\n", row.frame, row.sample))
  end
  file:close()
  return true
end

local function dump_all(reason)
  if dumped then return end
  dumped = true
  local meta = io.open(prefix .. "_meta.tsv", "w")
  if meta == nil then emu.log("TITLE MENU CAPTURE: dump 폴더에 쓸 수 없다"); return end
  meta:write("version\treason\tframe\tid\tword_address\twords\tbytes\tdescription\n")
  for _, block in ipairs(BLOCKS) do
    local name = prefix .. "_" .. block.id .. "_" .. string.format("%04X", block.word) .. ".bin"
    local ok = write_binary(name, VRAM, block.word * 2, block.words * 2)
    meta:write(string.format("%s\t%s\t%d\t%s\t%04X\t%d\t%d\t%s%s\n", VERSION, reason, frame,
      block.id, block.word, block.words, block.words * 2, block.text, ok and "" or " [WRITE FAILED]"))
  end
  meta:close()

  -- SATB = 512B, CRAM is normally 1024B. getMemorySize is used when available.
  write_binary(prefix .. "_satb_1000.bin", VRAM, 0x2000, 0x200)
  dump_sprite_table(prefix .. "_satb_vram.tsv", VRAM, 0x2000, "VRAM")
  write_binary(prefix .. "_sprite_ram.bin", SPR, 0, 0x200)
  dump_sprite_table(prefix .. "_sprite_ram.tsv", SPR, 0, "SPR")
  local cram_bytes = 0x400
  if type(emu.getMemorySize) == "function" then
    local ok, size = pcall(emu.getMemorySize, CRAM)
    if ok and type(size) == "number" and size > 0 then cram_bytes = size end
  end
  write_binary(prefix .. "_cram.bin", CRAM, 0, cram_bytes)
  dump_trace(prefix .. "_725c_trace.tsv")
  emu.log("TITLE MENU CAPTURE complete -> " .. prefix .. "_meta.tsv")
  emu.log(string.format("  VRAM blocks %d · SATB + Sprite RAM 512B · CRAM %dB · $725C traces %d", #BLOCKS, cram_bytes, #trace))
end

emu.addEventCallback(function()
  frame = frame + 1
  if frame == 120 then dump_all("auto_2_seconds") end
end, emu.eventType.endFrame)
emu.addEventCallback(function() dump_all("script_stopped") end, emu.eventType.scriptEnded)

emu.log("TITLE MENU SPRITE CAPTURE " .. VERSION .. " loaded (read-only)")
emu.log("  타이틀 메뉴가 보이는 상태에서 2초 기다리면 dump/title_menu_* 이 생긴다")
emu.log("  Script -> Settings -> Restrictions -> Allow I/O and OS 필요")
