-- PROBE_ADPCM_ID 0.1.1 -- length 가 RAM 어디에 있나 (2026-08-26)
--
-- 0.1.0 이 답한 것
-- ---------------
--     ✓ 재생 직전 프레임에 ADPCM RAM 이 이미 차 있다 (5/5 같음)
--       -> 재생 **전에** 표본을 뜰 수 있다.  포트 읽기가 소리를 깨뜨리나 하는
--          위험한 질문이 사라졌다
--     ✓ end  = $22A6/$22A7   (리틀엔디언)
--     ✓ rate = $22AA
--     ✗ length 는 $22A0-$22AF 에 **없다**.  그 블록은 나머지가 전부 0 이다
--
-- 왜 없나
-- -------
-- 수집기도 `cdrom.adpcm.adpcmLength` -- 즉 **ADPCM 칩 내부 레지스터**에서 읽는다.
-- CPU 메모리가 아니다.  `$22A6`/`$22AA` 는 게임이 칩에 명령을 내리려고 RAM 에
-- 준비해 둔 사본이라 end 와 rate 만 있다.
--
-- 그럼 length 는
-- --------------
-- 게임이 "이만큼 실어라" 를 어딘가에 갖고 있을 것이다 -- 아니면 애초에 전송을
-- 못 건다.  **짐작으로 한 자리를 찍지 않는다.**  워크램 `$2000-$3FFF` 를
-- 통째로 훑어 그 프레임의 실제 length 와 같은 16 비트 값이 **어디에 있는지**
-- 전부 남긴다.  음성 대여섯 개에서 **같은 자리**가 계속 나오면 그것이 length 다.
--
-- 없을 수도 있다.  그러면 length 를 열쇠에서 빼고 소리 표본을 늘려야 한다
-- (오프라인 측정: end+rate+소리 32 B = 365/389, 표본을 늘리면 더 오른다).
-- 그때는 그쪽으로 간다.
--
-- 쓰는 법
-- -------
--   1) Mesen 에 올린다
--   2) 대사 대여섯 개를 듣는다
--   3) Stop  ->  dump/adpcm_len_0_1_1_<시각>.tsv

local MEM  = emu.memType.pceMemory

local SCAN_FROM, SCAN_TO = 0x2000, 0x3FFF     -- 워크램
local stamp = os.date("%Y%m%d_%H%M%S")
local PATH = "C:\\snatcher\\dump\\adpcm_len_0_1_1_" .. stamp .. ".tsv"

local rows = {}
local frames, voices = 0, 0
local was_playing = false
local prev = nil                              -- 재생 직전 프레임의 워크램

local function snapshot()
  local out = {}
  for a = SCAN_FROM, SCAN_TO do out[#out + 1] = emu.read(a, MEM) or 0 end
  return out
end

local function find16(block, want)
  local out = {}
  for i = 1, #block - 1 do
    if (block[i] | (block[i + 1] << 8)) == want then
      out[#out + 1] = string.format("%04X:LE", SCAN_FROM + i - 1)
    elseif (block[i + 1] | (block[i] << 8)) == want then
      out[#out + 1] = string.format("%04X:BE", SCAN_FROM + i - 1)
    end
    if #out >= 40 then break end
  end
  return out
end

emu.addEventCallback(function()
  frames = frames + 1
  local ok, s = pcall(emu.getState)
  if not ok or not s then return end

  local playing = s["cdrom.adpcm.playing"] == true
  if playing and not was_playing then
    voices = voices + 1
    -- 정답은 칩 레지스터에서 (콘솔은 못 보지만, 우리가 대조하려고 쓴다)
    local length = s["cdrom.adpcm.adpcmLength"] or 0
    local read_addr = s["cdrom.adpcm.readAddress"] or 0
    local sector = s["cdrom.scsi.sector"] or -1
    local end_addr = (emu.read(0x22A6, MEM) or 0) | ((emu.read(0x22A7, MEM) or 0) << 8)

    -- 재생 직전 프레임에서 찾는다.  재생이 시작되면 값이 소비돼 사라질 수 있다.
    local before = prev or snapshot()
    local now = snapshot()

    rows[#rows + 1] = table.concat({
      voices, frames, string.format("%06X", sector),
      string.format("%04X", end_addr), string.format("%04X", length),
      string.format("%04X", read_addr),
      table.concat(find16(before, length), ","),
      table.concat(find16(now, length), ","),
      table.concat(find16(before, read_addr), ","),
    }, "\t")

    emu.log(string.format("[음성 %d] len %04X · read %04X · 직전프레임에서 %d 곳 발견",
                          voices, length, read_addr, #find16(before, length)))
  end
  was_playing = playing
  prev = snapshot()
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  local file = io.open(PATH, "w")
  if file == nil then return end
  file:write("n\tframe\tsector\tend_addr\tlength\tread_addr\t"
             .. "len_at_before\tlen_at_now\tread_at_before\n")
  file:write(table.concat(rows, "\n") .. "\n")
  file:close()
  emu.log(string.format("ADPCM LEN -- 음성 %d 개 -> %s", voices, PATH))
  emu.log("  여러 음성에서 **같은 자리**가 나오면 그것이 length 다")
end, emu.eventType.scriptEnded)

emu.log("PROBE_ADPCM_ID 0.1.1 -- 워크램 $2000-$3FFF 를 훑어 length 자리를 찾는다")
emu.log("  대사 대여섯 개 들은 뒤 Stop.  -> " .. PATH)
