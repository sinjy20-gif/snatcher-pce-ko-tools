-- PROBE_GFX_UPLOAD 0.1.3 -- 소스 데이터를 통째로 뜬다 (2026-08-25)
--
-- 0.1.2 가 알아낸 것 (그리고 뒤집은 것)
-- ------------------------------------
-- `LDA ($14),Y` 는 **그림 소스가 아니었다.**
--
--     소스 읽기 260 건   (버퍼 쓰기는 23,969 건)
--     ($14) = $3500 · Y 는 AND #$0F 로 0-15 만
--     $3500 은 거의 0 -- 16 엔트리 룩업표다
--
-- 260 / 8 = 32.  단색 타일 몇 장 칠하는 보조 루틴이지 그림 경로가 아니다.
-- 0.1.2 의 전제가 틀렸다.
--
-- 대신 MPR 이 길을 알려줬다
-- ------------------------
--     MPR: FF F8 68 6A 7C 7D 7F 00
--
--     $0000-$1FFF  FF  I/O
--     $2000-$3FFF  F8  워크램      ($3B00 버퍼가 여기)
--     $4000-$5FFF  68
--     $6000-$7FFF  6A  지금 도는 코드
--     $8000-$DFFF  7C 7D 7F  ★ CD 에서 읽어 온 데이터
--
-- 그래서 이 판이 할 일
-- --------------------
--     1  $8000-$DFFF 를 통째로 뜬다        24 KB.  디스크와 바로 대조된다
--     2  거기를 **읽는** 코드를 잡는다      PC 별로 센다 -- 그림 읽는 쪽이 나온다
--     3  $4000-$7FFF 도 같이 뜬다          코드와 중간 버퍼가 여기 있다
--
-- 1 만으로도 크다.  뜬 바이트를 디스크에서 찾으면 **원본 위치가 확정**되고,
-- 그러면 압축인지 아닌지도 그때 갈린다 (그대로 있으면 무압축이다).
--
-- 쓰는 법
-- -------
--   1) Mesen 에 올린다  (다른 스크립트와 같이 올리지 말 것)
--   2) 깁슨 환경 A 컴퓨터 화면을 띄운다.  글이 다 뜰 때까지 기다린다
--   3) Stop

local MEM = emu.memType.pceMemory

local SRC_FROM, SRC_TO = 0x8000, 0xDFFF   -- CD RAM 창
local MID_FROM, MID_TO = 0x4000, 0x7FFF   -- 코드·중간 버퍼
local BUF_WRITE = { 0x71B8, 0x7220 }      -- $3B00 에 STA 하는 자리 (0.1.1 확인)

local stamp = os.date("%Y%m%d_%H%M%S")
local BASE  = "C:\\snatcher\\dump\\gfx_upload_0_1_3_" .. stamp

local readPcs  = {}      -- $8000-$DFFF 를 읽은 PC -> 횟수
local readAddr = {}      -- 읽은 주소를 8KB 단위로 -> 횟수
local reads, fills = 0, 0
local frames = 0
local dumped = false
local lastFill = -1
local lastSector = -1
local sectors = {}
local mprSeen = {}

local function state_get()
  local ok, s = pcall(emu.getState)
  if ok then return s end
  return nil
end

local function mpr_string(s)
  if s == nil then return "?" end
  local out = {}
  for i = 0, 7 do
    local v = s["memoryManager.mpr[" .. i .. "]"]
    out[#out + 1] = type(v) == "number" and string.format("%02X", v) or "??"
  end
  return table.concat(out, " ")
end

-- ---------------------------------------------------------------- 읽는 쪽
-- 읽기 콜백은 Mesen 판에 따라 없을 수 있다.  없으면 조용히 넘어간다 --
-- 덤프(1번)만으로도 이 판의 목적은 이룬다.
local okRead = pcall(function()
  emu.addMemoryCallback(function(address, value)
    reads = reads + 1
    if reads % 4 ~= 0 then return end      -- 너무 잦다.  4 건에 하나만 센다
    local s = state_get()
    local pc = s and s["cpu.pc"] or 0
    readPcs[pc] = (readPcs[pc] or 0) + 1
    local bucket = address & 0xE000
    readAddr[bucket] = (readAddr[bucket] or 0) + 1
  end, emu.callbackType.read, SRC_FROM, SRC_TO, emu.cpuType.pce, MEM)
end)

-- ---------------------------------------------------------------- 버퍼가 차는 순간
for _, at in ipairs(BUF_WRITE) do
  emu.addMemoryCallback(function()
    fills = fills + 1
    lastFill = frames
    if #mprSeen < 8 then
      local s = state_get()
      mprSeen[#mprSeen + 1] = string.format("프레임 %d  %s", frames, mpr_string(s))
    end
  end, emu.callbackType.exec, at, at, emu.cpuType.pce, MEM)
end

-- ---------------------------------------------------------------- 뜨기
local function dump_range(path, from, to)
  local file = io.open(path, "wb")
  if file == nil then
    emu.log("GFX ERROR 못 연다: " .. path)
    return
  end
  local chunk = {}
  for address = from, to do
    chunk[#chunk + 1] = string.char(emu.read(address, MEM) or 0)
    if #chunk >= 4096 then file:write(table.concat(chunk)); chunk = {} end
  end
  if #chunk > 0 then file:write(table.concat(chunk)) end
  file:close()
  emu.log(string.format("GFX $%04X-$%04X -> %s", from, to, path))
end

local function dump_all(tag)
  dump_range(BASE .. "_src_" .. tag .. ".bin", SRC_FROM, SRC_TO)
  dump_range(BASE .. "_mid_" .. tag .. ".bin", MID_FROM, MID_TO)
end

emu.addEventCallback(function()
  frames = frames + 1
  local s = state_get()
  if s then
    local sector = s["cdrom.scsi.sector"]
    if type(sector) == "number" and sector ~= lastSector then
      lastSector = sector
      sectors[#sectors + 1] = { frame = frames, sector = sector }
      if #sectors > 96 then table.remove(sectors, 1) end
    end
  end

  -- 버퍼 채우기가 멎으면 그때가 화면이 다 올라간 순간이다.  **그 상태**를 뜬다 --
  -- 0.1.0 은 한참 뒤에 떠서 소스가 이미 지나간 뒤였다.
  if not dumped and fills > 1000 and lastFill > 0 and frames - lastFill > 20 then
    dumped = true
    dump_all("settled")
    emu.log("GFX 0.1.3 -- 채우기가 멎어 소스를 떴다")
  end

  if frames % 1800 == 0 then
    emu.log(string.format("GFX 0.1.3 -- 버퍼채움 %d · 소스읽기 %d · 떴나 %s",
                          fills, reads, tostring(dumped)))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if not dumped then dump_all("stop") end     -- 멎는 걸 못 봤으면 지금이라도
  dump_all("final")

  local file = io.open(BASE .. "_report.txt", "w")
  if file == nil then return end
  file:write("PROBE_GFX_UPLOAD 0.1.3  " .. stamp .. "\n")
  file:write(string.format("버퍼 채움 %d 건 · $%04X-$%04X 읽기 %d 건 (읽기훅 %s)\n\n",
                           fills, SRC_FROM, SRC_TO, reads,
                           okRead and "걸림" or "★ 이 Mesen 판엔 없다"))

  if fills == 0 then
    file:write("★ 버퍼를 한 번도 안 채웠다 -- 화면을 안 띄웠거나 다른 경로다\n\n")
  end

  file:write("-- MPR (버퍼 채우는 순간) --\n")
  for _, line in ipairs(mprSeen) do file:write("  " .. line .. "\n") end

  file:write("\n-- $8000-$DFFF 를 읽은 코드 (많은 순) --\n")
  local list = {}
  for pc, n in pairs(readPcs) do list[#list + 1] = { pc = pc, n = n } end
  table.sort(list, function(a, b) return a.n > b.n end)
  for i = 1, math.min(#list, 24) do
    file:write(string.format("  $%04X  %d\n", list[i].pc, list[i].n))
  end

  file:write("\n-- 읽은 자리 (8KB 단위) --\n")
  for bucket, n in pairs(readAddr) do
    file:write(string.format("  $%04X  %d\n", bucket, n))
  end

  file:write("\n-- 최근 CD 섹터 --\n")
  for _, e in ipairs(sectors) do
    file:write(string.format("  프레임 %6d  섹터 %d (0x%X)\n", e.frame, e.sector, e.sector))
  end

  file:write("\n-- 다음 --\n")
  file:write("  뜬 _src_*.bin 을 디스크(dump/track02_userdata.bin)에서 찾는다.\n")
  file:write("  그대로 나오면 무압축이고 원본 위치가 확정된다.\n")
  file:close()
  emu.log("GFX 0.1.3 보고서 -> " .. BASE .. "_report.txt")
end, emu.eventType.scriptEnded)

emu.log("PROBE_GFX_UPLOAD 0.1.3 -- CD RAM 창($8000-$DFFF)을 통째로 뜬다")
emu.log("  깁슨 컴퓨터 화면을 띄운 뒤 Stop.  -> " .. BASE .. "_*.bin · _report.txt")
