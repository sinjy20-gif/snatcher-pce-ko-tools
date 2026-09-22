-- PROBE_ADPCM_ID 0.1.0 -- 콘솔이 음성을 구분할 재료를 다 갖고 있나 (2026-08-26)
--
-- 왜 이걸 재나
-- ------------
-- 자막 열쇠에서 `sector` 를 빼야 한다.  BIOS 호출 이력을 통째로 뒤져도 없었고
-- (PROBE_CD_SECTOR 0.1.0~0.1.2), 애초에 그것은 **적재가 끝난 뒤 드라이브가 멈춘
-- 자리**일 뿐 음성의 신원이 아니었다.  신원은 ADPCM RAM 에 실린 소리다.
--
-- 오프라인 측정(클립 389 개)으로 이미 확인한 것:
--
--     (end, rate, length)                     282/389   부족
--     (end, rate, length) + 소리 6 B 표본       388/389   ★ 충분
--     남은 1 조합은 51,095 B 가 한 바이트도 안 다른 **같은 음성**이다
--
-- 이 판이 묻는 것은 딱 둘이다
-- ---------------------------
--     1  `length` 가 CPU 가 읽을 수 있는 자리에 있나 · 어디인가
--        상주부는 이미 $22A6(끝주소)·$22AA(재생률)을 읽는다.  length 는 모른다.
--        **짐작으로 $22A8 을 찍지 않는다** -- $22A0-$22AF 를 통째로 남기고
--        나중에 클립의 실제 길이와 대조해 자리를 찾는다.
--
--     2  재생 **직전 프레임**에 ADPCM RAM 이 이미 차 있나
--        차 있으면 재생 전에 표본을 뜰 수 있고, "재생 중 포트 읽기가 소리를
--        깨뜨리나" 라는 위험한 질문 자체가 없어진다.
--
-- 표본 자리는 아직 못 정한다 (read_address 를 모르므로).  그래서 이 판은
-- **ADPCM RAM 앞 32 B 를 고정으로** 뜬다 -- 재생 전/후가 같은지만 보면 2 번은
-- 답이 나온다.  표본 자리 결정은 1 번이 풀린 다음 판에서 한다.
--
-- 쓰는 법
-- -------
--   1) Mesen 에 올린다
--   2) 접수처까지 가서 대사 대여섯 개를 듣는다
--   3) Stop  ->  dump/adpcm_id_0_1_0_<시각>.tsv
--
-- 대조는 오프라인에서 한다: `sector` 로 voice_keys.tsv 의 그 음성을 찾고,
-- 거기 적힌 audio_length 가 $22A0-$22AF 중 어느 자리와 맞는지 본다.

local MEM  = emu.memType.pceMemory
local APCM = emu.memType.pceAdpcmRam

local REG_FROM, REG_N = 0x22A0, 16
local RAM_N = 32                      -- ADPCM RAM 앞 몇 바이트를 볼까

local stamp = os.date("%Y%m%d_%H%M%S")
local PATH = "C:\\snatcher\\dump\\adpcm_id_0_1_0_" .. stamp .. ".tsv"

local rows = {}
local frames, voices = 0, 0
local was_playing = false
local prev_regs, prev_ram = nil, nil

local function read_block(base, count, kind)
  local out = {}
  for i = 0, count - 1 do out[#out + 1] = emu.read(base + i, kind) or 0 end
  return out
end

local function hex(list)
  local out = {}
  for _, v in ipairs(list) do out[#out + 1] = string.format("%02X", v) end
  return table.concat(out, " ")
end

emu.addEventCallback(function()
  frames = frames + 1
  local ok, s = pcall(emu.getState)
  if not ok or not s then return end

  local regs = read_block(REG_FROM, REG_N, MEM)
  -- ADPCM RAM 은 Lua 로 읽는다.  에뮬레이터 쪽 읽기라 소리를 안 건드린다.
  local ram = read_block(0, RAM_N, APCM)

  local playing = s["cdrom.adpcm.playing"] == true
  if playing and not was_playing then
    voices = voices + 1
    local end_addr = regs[7] | (regs[8] << 8)        -- $22A6/$22A7 (상주부가 읽는 자리)
    local rate = regs[11]                             -- $22AA
    local sector = s["cdrom.scsi.sector"] or -1
    local before_regs = prev_regs or regs
    local before_ram = prev_ram or ram

    rows[#rows + 1] = table.concat({
      voices, frames,
      string.format("%04X", end_addr), string.format("%02X", rate),
      string.format("%06X", sector),
      hex(regs), hex(before_regs),
      hex(ram), hex(before_ram),
      (hex(ram) == hex(before_ram)) and "same" or "DIFF",
    }, "\t")

    emu.log(string.format("[음성 %d] 끝 %04X · rate %02X · sector %06X · RAM 재생전후 %s",
                          voices, end_addr, rate, sector,
                          (hex(ram) == hex(before_ram)) and "같음" or "다름"))
  end

  was_playing = playing
  prev_regs, prev_ram = regs, ram
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  local file = io.open(PATH, "w")
  if file == nil then return end
  file:write("n\tframe\tend_addr\trate\tsector\tregs_now\tregs_before\t"
             .. "ram_now\tram_before\tram_same\n")
  file:write(table.concat(rows, "\n") .. "\n")
  file:close()
  emu.log(string.format("ADPCM ID -- 음성 %d 개 -> %s", voices, PATH))
  emu.log("  오프라인에서 sector 로 voice_keys 를 찾아 length 자리를 맞춘다")
end, emu.eventType.scriptEnded)

emu.log("PROBE_ADPCM_ID 0.1.0 -- 대사 대여섯 개 들은 뒤 Stop")
emu.log("  묻는 것: length 가 $22A0-$22AF 어디에 있나 · 재생 전에 RAM 이 차 있나")
emu.log("  -> " .. PATH)
