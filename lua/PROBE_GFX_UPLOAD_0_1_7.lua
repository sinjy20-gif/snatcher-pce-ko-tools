-- PROBE_GFX_UPLOAD 0.1.7 -- VDC 레지스터까지 같이 뜬다 (2026-08-25)
--
-- 0.1.5 에서 또 걸린 것
-- ---------------------
-- 분석 쪽이 **BAT 이 워드 0 에 64x64** 라고 가정하고 렌더했다.  화면마다 크기가
-- 다르므로(MWR 이 정한다) 그 가정이 틀리면 타일 번호가 엉뚱하게 읽히고 그림이
-- 깨진다.  실제로 깨졌다.
--
-- 그래서 VDC 레지스터를 같이 뜬다.  레지스터 쓰기는 화면당 몇 백 번이라
-- 부담이 없다 (버퍼 채우기는 2 만 번인 것과 다르다).
--
--     reg $09  MWR   화면 크기 (BAT 이 몇 x 몇 인가)
--     reg $05  CR    증가 폭
--     reg $07/$08    BXR/BYR 스크롤
--
-- 이게 있어야 뜬 VRAM 을 **올바르게** 그림으로 되돌릴 수 있다.
--
-- 0.1.4 가 알아낸 것
-- ------------------
-- CD RAM($8000-$DFFF)이 **디스크와 바이트가 같다** (357/357).
--
--     CPU $8000-$BFFF (뱅크 86·87) -> 디스크 0x6E000  (LBA 295)
--     CPU $C000-$DFFF (뱅크 84/85) -> 디스크 0x68000  (LBA 283)
--
-- 디스크에서 RAM 까지는 무압축이다.  압축 역공학은 아마 필요 없다.
--
-- 왜 이 판이 필요한가
-- -------------------
-- 0.1.4 는 소스만 떴고 VRAM 은 **다른 실행**의 것을 썼다.  그래서 "소스에서
-- 타일이 안 나온다" 가 형식 차이인지 화면 차이인지 못 가렸다.  대조가 성립하려면
-- 둘을 **같은 순간에** 떠야 한다.
--
-- 그래서 이 판은 셋을 한 번에 뜬다.
--
--     VRAM 64 KB            정답 (변환된 결과)
--     $8000-$DFFF 24 KB     소스 (디스크 그대로인 것이 확인된 자리)
--     $4000-$7FFF 16 KB     코드와 중간 버퍼
--
-- 0.1.3 은 못 쓴다 -- 에뮬이 기어갔다
-- ------------------------------------
-- $8000-$DFFF 에 **읽기 훅**을 걸었는데, 그 범위는 코드·데이터 읽기가 초당
-- 수십만 번이다.  거기서 emu.getState() 를 부르니 게임이 못 돌 정도로 느려졌다.
--
-- 읽기 훅을 뺐다.  답을 주는 것은 **덤프**이고 읽기 PC 는 덤이었다.
-- 훅이 남은 것은 버퍼 채우는 두 자리뿐이고, 그건 화면당 2 만 번이라 부담이 없다
-- (게다가 getState 를 안 부른다).
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
-- $2000 부터 뜬다.  0.1.6 은 $4000 부터라 정작 중요한 둘을 빠뜨렸다:
--     $2000-$20FF  진짜 제로페이지 (소스 포인터가 여기 산다)
--     $3B00-$3B7F  스테이징 버퍼 (플레인으로 바뀌기 직전의 데이터)
local MID_FROM, MID_TO = 0x2000, 0x7FFF   -- 제로페이지 · 버퍼 · 코드
local BUF_WRITE = { 0x71B8, 0x7220 }      -- $3B00 에 STA 하는 자리 (0.1.1 확인)

local stamp = os.date("%Y%m%d_%H%M%S")
local BASE  = "C:\\snatcher\\dump\\gfx_upload_0_1_7_" .. stamp

local readPcs  = {}      -- $8000-$DFFF 를 읽은 PC -> 횟수
local readAddr = {}      -- 읽은 주소를 8KB 단위로 -> 횟수
local reads, fills = 0, 0
local frames = 0
local dumped = false
local lastFill = -1
local lastSector = -1
local sectors = {}
local mprSeen = {}
local mprWanted = false

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

-- 읽기 훅은 없앴다 (0.1.3 이 그것 때문에 못 돌았다).
local okRead = false

-- ---------------------------------------------------------------- VDC 레지스터
-- 레지스터 선택($0000)과 데이터($0002/$0003)를 따라가 마지막 값을 들고 있는다.
local vdcReg  = 0
local vdcLow  = 0
local vdcRegs = {}

emu.addMemoryCallback(function(address, value)
  vdcReg = value & 0x1F
end, emu.callbackType.write, 0x0000, 0x0000, emu.cpuType.pce, MEM)

emu.addMemoryCallback(function(address, value)
  vdcLow = value
end, emu.callbackType.write, 0x0002, 0x0002, emu.cpuType.pce, MEM)

emu.addMemoryCallback(function(address, value)
  -- 데이터 포트(reg $02)는 VRAM 쓰기라 여기 담으면 안 된다 -- 값이 매번 바뀐다.
  if vdcReg == 0x00 or vdcReg == 0x02 then return end
  vdcRegs[vdcReg] = (value << 8) | vdcLow
end, emu.callbackType.write, 0x0003, 0x0003, emu.cpuType.pce, MEM)

-- ---------------------------------------------------------------- 버퍼가 차는 순간
for _, at in ipairs(BUF_WRITE) do
  emu.addMemoryCallback(function()
    -- 여기서는 **아무것도 부르지 않는다.**  화면당 2 만 번 도는 자리라
    -- getState 하나만 끼어도 에뮬이 눈에 띄게 느려진다.
    fills = fills + 1
    lastFill = frames
    mprWanted = true
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

local function dump_vram(path)
  local file = io.open(path, "wb")
  if file == nil then return end
  local chunk = {}
  for word = 0, 0x7FFF do
    local value = emu.read(word, emu.memType.pceVideoRam) or 0
    chunk[#chunk + 1] = string.char(value & 0xFF, (value >> 8) & 0xFF)
    if #chunk >= 4096 then file:write(table.concat(chunk)); chunk = {} end
  end
  if #chunk > 0 then file:write(table.concat(chunk)) end
  file:close()
  emu.log("GFX VRAM -> " .. path)
end

-- 셋을 **연달아** 뜬다.  사이에 프레임이 흐르면 대조가 또 어긋난다.
local function dump_all(tag)
  dump_range(BASE .. "_src_" .. tag .. ".bin", SRC_FROM, SRC_TO)
  dump_range(BASE .. "_mid_" .. tag .. ".bin", MID_FROM, MID_TO)
  dump_vram(BASE .. "_vram_" .. tag .. ".bin")
end

emu.addEventCallback(function()
  frames = frames + 1
  local s = state_get()
  -- MPR 은 프레임에 한 번만 본다 -- 버퍼 훅 안에서 보면 너무 비싸다
  if mprWanted and #mprSeen < 8 then
    mprWanted = false
    mprSeen[#mprSeen + 1] = string.format("프레임 %d  %s", frames, mpr_string(s))
  end
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
    emu.log("GFX 0.1.7 -- 채우기가 멎어 소스를 떴다")
  end

  if frames % 1800 == 0 then
    emu.log(string.format("GFX 0.1.7 -- 버퍼채움 %d · 소스읽기 %d · 떴나 %s",
                          fills, reads, tostring(dumped)))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if not dumped then dump_all("stop") end     -- 멎는 걸 못 봤으면 지금이라도
  dump_all("final")

  local file = io.open(BASE .. "_report.txt", "w")
  if file == nil then return end
  file:write("PROBE_GFX_UPLOAD 0.1.7  " .. stamp .. "\n")
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
  emu.log("GFX 0.1.7 보고서 -> " .. BASE .. "_report.txt")
end, emu.eventType.scriptEnded)

emu.log("PROBE_GFX_UPLOAD 0.1.7 -- CD RAM 창($8000-$DFFF)을 통째로 뜬다")
emu.log("  깁슨 컴퓨터 화면을 띄운 뒤 Stop.  -> " .. BASE .. "_*.bin · _report.txt")
