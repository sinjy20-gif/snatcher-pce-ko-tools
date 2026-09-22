-- PROBE AC내용 0.1.0 -- 레코드 주소는 맞는데 캐시가 0 인 이유
--
-- 어디까지 왔나 (2026-08-18 밤, 전부 실측)
-- ---------------------------------------------------------------------------
--   FONT_ADDR 0.1.6    EX_GETFNT 202 회 · 한글코드 0 회        폰트 문제 아님
--   RECORD_PATH 0.1.0  init_ok · lookup -> valid -> copy_record 레코드는 실린다
--                      valid 가 돌려준 AC 주소: pack00 $016000 · pack01 $01EA00
--                                               pack02 $048820
--   PRELOADER 0.1.0    slot_loaded 33 · **캐시 매직 00 00 00 00** · sig 0
--                      CHECKS_OK 0 · search_failed 35
--
-- 즉 조회는 정상이고 copy_record 도 도는데 **캐시에 0 이 들어온다.**
-- 그러면 copy_record 가 읽은 AC 자리에 아무것도 없다는 뜻이다.
--
-- 정적으로 걸린 것 -- 이미지 배치와 목적지가 $4000 어긋난다
-- ---------------------------------------------------------------------------
--     disc_package_image.bin 안에서 'SDR4' 첫 위치   $12000
--     그런데 pack0 speaker 의 destination           $16000
--   두 빌드(0.3.11-bios-opt · 0.3.12) 가 똑같이 이렇다.  0.3.11 은 한글이 나왔으므로
--   "이미지를 AC 0 번지에 통째로 올린다" 는 내 모델이 틀렸을 수 있다.
--   **추측을 끝내려면 AC 를 직접 봐야 한다.**
--
-- 이 프로브가 답하는 것
-- ---------------------------------------------------------------------------
--   1. AC 의 각 구간에 실제로 무엇이 있는가 ($00000 디렉터리 · $12000 · $16000 ·
--      $17800 · $2E000).  'SDR4'(53 44 52 34) 가 보이는 자리가 진짜 팩 시작이다
--   2. copy_record 직후 캐시 $5B80 에 무엇이 들어갔는가
--   3. 그때 레코드가 가리킨 AC 주소에 무엇이 있는가
--
--   -> AC 어딘가에 'SDR4' 가 있는데 레코드 주소에는 없다면 **주소 오프셋 문제**다.
--      AC 어디에도 없다면 **초기 적재가 안 된 것**이다 (init_ok 는 떴지만).
--
-- 돌리는 법
-- ---------------------------------------------------------------------------
--   디스크  build\patch\0.4.1-bios\...[KO 0.3.12-bios] (0818-2000).cue
--   파워 사이클 -> 접수처 대사까지.  스크립트를 멈추면 마지막 스냅샷이 붙는다.
--   출력: C:\snatcher\dump\probe_ac_content_0_1_0.tsv

local OUT = "C:\\snatcher\\dump\\probe_ac_content_0_1_0.tsv"
local mem = emu.memType.pceMemory

local ac = nil
for name, value in pairs(emu.memType or {}) do
  if string.lower(name) == "pcearcadecardram" then ac = value end
end

local RETURN_STATUS = 0xBE57      -- copy_record 가 끝나고 돌아가는 지점
local INIT_OK       = 0xBD40
local CACHE = 0x5B80
local SCRATCH = 0xBFE0
local PACK_ID, REC_LO, REC_MID, REC_HI = SCRATCH + 8, SCRATCH + 9, SCRATCH + 10, SCRATCH + 11

-- 훑어볼 AC 구간.  이름은 manifest 기준
local SPOTS = {
  { 0x000000, "디렉터리 선두" },
  { 0x010020, "metadata_ac" },
  { 0x010200, "template_ac" },
  { 0x012000, "이미지상 'SDR4' 위치" },
  { 0x016000, "pack0 speaker dest (common_data_base)" },
  { 0x017800, "pack1 ui dest" },
  { 0x02E000, "pack2 runtime dest" },
  { 0x048820, "관측된 pack2 레코드 주소" },
}

local file = assert(io.open(OUT, "w"))
file:write("kind\tframe\taddr\tbytes\tascii\tnote\n")

local frame, dirty, logged = 0, false, 0
local shots = 0
local LOG_MAX = 20

local function byte(a) return emu.read(a, mem) or 0 end

local function dump(space, addr, count)
  local hex, txt = {}, {}
  for k = 0, count - 1 do
    local v = emu.read(addr + k, space) or 0
    hex[#hex + 1] = string.format("%02X", v)
    txt[#txt + 1] = (v >= 0x20 and v < 0x7F) and string.char(v) or "."
  end
  return table.concat(hex, " "), table.concat(txt)
end

local function row(kind, addr, hex, txt, note)
  file:write(string.format("%s\t%d\t%s\t%s\t%s\t%s\n",
    kind, frame, addr and string.format("%06X", addr) or "",
    hex or "", txt or "", note or ""))
  dirty = true
end

local function snapshot(tag)
  shots = shots + 1
  if ac == nil then
    row("AC", nil, "", "", "★ Mesen 에 pceArcadeCardRam 이 없다 -- AC 가 안 붙어 있다")
    return
  end
  for _, spot in ipairs(SPOTS) do
    local hex, txt = dump(ac, spot[1], 16)
    row("AC", spot[1], hex, txt, tag .. " -- " .. spot[2])
  end
end

emu.addMemoryCallback(function()
  row("init_ok", nil, "", "", "초기 AC 적재 성공 직후")
  snapshot("init_ok")
end, emu.callbackType.exec, INIT_OK, INIT_OK, emu.cpuType.pce, mem)

emu.addMemoryCallback(function()
  if logged >= LOG_MAX then return end
  logged = logged + 1
  local rec = byte(REC_LO) + byte(REC_MID) * 256 + byte(REC_HI) * 65536
  local chex, ctxt = dump(mem, CACHE, 16)
  row("cache", CACHE, chex, ctxt,
    string.format("copy_record 직후 · pack %02X · 레코드 AC $%06X",
      byte(PACK_ID), rec))
  if ac ~= nil then
    local ahex, atxt = dump(ac, rec, 16)
    row("rec", rec, ahex, atxt, "그 레코드 주소의 AC 내용")
  end
end, emu.callbackType.exec, RETURN_STATUS, RETURN_STATUS, emu.cpuType.pce, mem)

emu.addEventCallback(function()
  frame = frame + 1
  if dirty then file:flush() dirty = false end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  snapshot("종료 시점")
  row("summary", nil, "", "", string.format(
    "AC 핸들 %s · 스냅샷 %d · copy_record 기록 %d",
    (ac ~= nil) and "있음" or "★없음", shots, logged))
  file:close()
end, emu.eventType.scriptEnded)

emu.log("PROBE AC내용 0.1.0 -- AC 에 팩이 실제로 올라와 있는가")
emu.log("  'SDR4'(53 44 52 34) 가 어느 주소에서 보이는지가 답이다")
emu.log("  출력: " .. OUT)
