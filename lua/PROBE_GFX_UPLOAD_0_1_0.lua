-- PROBE_GFX_UPLOAD 0.1.0 -- 그림이 VRAM 에 올라가는 순간을 잡는다 (2026-08-25)
--
-- 무엇을 답하려는 프로브인가
-- --------------------------
-- 깁슨 컴퓨터 화면 12 장이 **그림**인 것은 확인됐다.  텍스트 경로를 안 타고
-- (수집기에 한 줄도 안 잡힌다), 디스크에 원문이 전각·반각 Shift-JIS 어느 쪽으로도
-- 0 건이며, VRAM 타일 259 개를 그대로 디스크에서 찾아도 안 나온다.  BAT 도 없다.
--
-- **그런데 "압축돼 있다" 는 아직 확정이 아니다.**  적재 후에 변환·재배치되는
-- 다른 포맷이어도 디스크 생검색에는 똑같이 안 잡힌다.  둘을 가르려면 올라가는
-- 순간을 봐야 한다.
--
-- 그래서 이 프로브는 **한 번 돌려서 세 가지를 같이** 뜬다.
--
--     1  누가 올리나      VRAM 에 쓰는 코드의 PC 분포
--     2  어디서 읽나      그 순간의 CPU RAM 전체 (압축을 푼 결과가 여기 있으면
--                         VRAM 타일 바이트가 RAM 에서 그대로 발견된다)
--     3  어느 섹터에서    직전에 읽은 CD 섹터 이력
--
-- 세 가지가 같이 있어야 답이 난다.
--
--     RAM 에서 타일이 발견됨 + 섹터 이력 있음  -> 디스크 blob 을 찾아 포맷을 뜯는다
--     RAM 에 없음                              -> CD 에서 VRAM 으로 직행.  DMA 경로다
--
-- 왜 VDC 포트를 보나
-- ------------------
-- PCE 는 VRAM 에 직접 못 쓴다.  레지스터를 고르고($0000) 데이터 포트($0002/$0003)로
-- 밀어 넣는다.  그래서 포트 쓰기를 보면서 주소를 따라가야 목적지를 안다.
--
--     reg $00  MAWR   쓸 주소
--     reg $02  VWR    데이터 (쓰면 주소가 증가한다)
--     reg $05  CR     증가 폭이 여기 들어 있다
--
-- 쓰는 법
-- -------
--   1) Mesen 에서 이 스크립트를 올린다
--   2) 깁슨 환경 A 컴퓨터 화면을 **띄운다** (글이 화면에 다 뜰 때까지)
--   3) Stop.  덤프 세 개가 dump/gfx_upload_0_1_0_<시각>* 로 남는다
--
-- 화면 하나면 충분하다.  12 장을 다 뜰 필요 없다 -- 포맷은 같을 것이고,
-- 다르면 그때 다시 돌리면 된다.

local MEM  = emu.memType.pceMemory
local VRAM = emu.memType.pceVideoRam

-- 그림 타일이 사는 자리.  실측: BAT 이 $0000-$0FFF 를 먹고 타일은 $1000 위부터다.
-- 덤프에서 쓰인 타일이 512-2047 이었으므로 워드로는 $2000 위다.
local WATCH_FROM = 0x1000        -- 이 워드 주소 위로 쓰는 것만 본다
local RAM_FROM, RAM_TO = 0x2000, 0x7FFF   -- 뜰 CPU RAM 범위
local SECTOR_KEEP = 64           -- 섹터 이력 몇 개나 들고 있을까

local stamp = os.date("%Y%m%d_%H%M%S")
local BASE  = "C:\\snatcher\\dump\\gfx_upload_0_1_0_" .. stamp
-- 판을 올리면 이 경로도 같이 올린다.  로그를 만든 코드가 없으면 로그를 못 읽는다.

-- ---------------------------------------------------------------- VDC 따라가기
local reg      = 0        -- 지금 고른 레지스터
local mawr     = 0        -- 쓸 주소 (워드)
local inc      = 1        -- 증가 폭
local pending  = nil      -- 하위 바이트를 받아 두는 자리

local writes   = 0        -- 감시 범위에 들어온 쓰기 수
local pcs      = {}       -- PC -> 횟수
local first    = nil      -- 처음 들어온 쓰기
local last     = nil
local lowest, highest = nil, nil

local sectors  = {}       -- 최근에 본 CD 섹터
local lastSector = -1
local frames   = 0
local dumped   = false

local function note_pc()
  local s = emu.getState()
  local pc = s and s["cpu.pc"] or 0
  pcs[pc] = (pcs[pc] or 0) + 1
  return pc, s
end

-- $0000 : 레지스터 선택
emu.addMemoryCallback(function(address, value)
  reg = value & 0x1F
end, emu.callbackType.write, 0x0000, 0x0000, emu.cpuType.pce, MEM)

-- $0002 : 하위 바이트 · $0003 : 상위 바이트 (쓰면 확정된다)
emu.addMemoryCallback(function(address, value)
  pending = value
end, emu.callbackType.write, 0x0002, 0x0002, emu.cpuType.pce, MEM)

emu.addMemoryCallback(function(address, value)
  local low = pending or 0
  local word = (value << 8) | low
  pending = nil

  if reg == 0x00 then          -- MAWR: 쓸 주소가 정해졌다
    mawr = word
    return
  end
  if reg == 0x05 then          -- CR: 증가 폭 (bit 11-12)
    local sel = (word >> 11) & 0x03
    inc = ({[0]=1, [1]=32, [2]=64, [3]=128})[sel] or 1
    return
  end
  if reg ~= 0x02 then return end   -- VWR 만 본다

  local at = mawr
  mawr = (mawr + inc) & 0xFFFF

  if at < WATCH_FROM then return end

  writes = writes + 1
  local pc, state = note_pc()
  if first == nil then
    first = { frame = frames, at = at, pc = pc, sector = lastSector }
  end
  last = { frame = frames, at = at, pc = pc, sector = lastSector }
  if lowest  == nil or at < lowest  then lowest  = at end
  if highest == nil or at > highest then highest = at end
end, emu.callbackType.write, 0x0003, 0x0003, emu.cpuType.pce, MEM)

-- ---------------------------------------------------------------- 섹터 이력
emu.addEventCallback(function()
  frames = frames + 1
  local ok, s = pcall(emu.getState)
  if ok and s then
    local sector = s["cdrom.scsi.sector"]
    if type(sector) == "number" and sector ~= lastSector then
      lastSector = sector
      sectors[#sectors + 1] = { frame = frames, sector = sector }
      if #sectors > SECTOR_KEEP then table.remove(sectors, 1) end
    end
  end

  -- 쓰기가 한동안 멎으면 그때가 화면이 다 올라간 순간이다.  그 상태의 RAM 을 뜬다.
  if not dumped and writes > 256 and last ~= nil and frames - last.frame > 30 then
    dumped = true
    dump_ram()
    emu.log("GFX 화면이 다 올라간 것 같다 -- RAM 을 떴다.  Stop 하면 나머지가 남는다")
  end
end, emu.eventType.endFrame)

-- ---------------------------------------------------------------- 뜨기
function dump_ram()
  local path = BASE .. "_ram.bin"
  local file, err = io.open(path, "wb")
  if file == nil then
    emu.log("GFX ERROR RAM 을 못 연다: " .. tostring(err))
    return
  end
  local chunk = {}
  for address = RAM_FROM, RAM_TO do
    chunk[#chunk + 1] = string.char(emu.read(address, MEM) or 0)
    if #chunk >= 4096 then file:write(table.concat(chunk)); chunk = {} end
  end
  if #chunk > 0 then file:write(table.concat(chunk)) end
  file:close()
  emu.log(string.format("GFX RAM $%04X-$%04X -> %s", RAM_FROM, RAM_TO, path))
end

local function dump_vram()
  local path = BASE .. "_vram.bin"
  local file = io.open(path, "wb")
  if file == nil then return end
  local chunk = {}
  for word = 0, 0x7FFF do
    local value = emu.read(word, VRAM) or 0
    chunk[#chunk + 1] = string.char(value & 0xFF, (value >> 8) & 0xFF)
    if #chunk >= 4096 then file:write(table.concat(chunk)); chunk = {} end
  end
  if #chunk > 0 then file:write(table.concat(chunk)) end
  file:close()
  emu.log("GFX VRAM -> " .. path)
end

emu.addEventCallback(function()
  if not dumped then dump_ram() end
  dump_vram()

  local path = BASE .. "_report.txt"
  local file = io.open(path, "w")
  if file == nil then return end

  file:write("PROBE_GFX_UPLOAD 0.1.0  " .. stamp .. "\n")
  file:write(string.format("VRAM 쓰기 %d 건 (워드 $%04X 위만 셌다)\n", writes, WATCH_FROM))
  if writes == 0 then
    file:write("\n★ 한 건도 안 잡혔다.  둘 중 하나다:\n")
    file:write("   - 화면을 안 띄웠다\n")
    file:write("   - VDC 포트를 안 거치고 올라간다 (DMA).  그러면 이 프로브로는 못 본다\n")
  else
    file:write(string.format("목적지 워드 범위  $%04X - $%04X\n", lowest or 0, highest or 0))
    file:write(string.format("처음  프레임 %d · $%04X 에 · PC $%04X · 섹터 %d\n",
                             first.frame, first.at, first.pc, first.sector))
    file:write(string.format("마지막 프레임 %d · $%04X 에 · PC $%04X · 섹터 %d\n",
                             last.frame, last.at, last.pc, last.sector))
    file:write("\n-- 올린 코드 (PC 별 횟수, 많은 순) --\n")
    local list = {}
    for pc, n in pairs(pcs) do list[#list + 1] = { pc = pc, n = n } end
    table.sort(list, function(a, b) return a.n > b.n end)
    for index = 1, math.min(#list, 20) do
      file:write(string.format("  $%04X  %d 회\n", list[index].pc, list[index].n))
    end
  end

  file:write("\n-- 최근 CD 섹터 --\n")
  for _, entry in ipairs(sectors) do
    file:write(string.format("  프레임 %6d  섹터 %d (0x%X)\n", entry.frame, entry.sector, entry.sector))
  end

  file:write("\n-- 다음에 할 것 --\n")
  file:write("  python tools/find_gfx_source.py " .. BASE .. "\n")
  file:write("  RAM 에서 VRAM 타일이 발견되면 -> 압축을 푼 결과가 RAM 에 있다\n")
  file:write("  안 되면 -> CD 에서 직행.  섹터 이력으로 디스크를 뒤진다\n")
  file:close()
  emu.log("GFX 보고서 -> " .. path)
end, emu.eventType.scriptEnded)

emu.log("PROBE_GFX_UPLOAD 0.1.0 -- 깁슨 컴퓨터 화면을 띄운 뒤 Stop 하면 된다")
emu.log("  뜨는 것: RAM $2000-$7FFF · VRAM 64KB · PC 분포 · CD 섹터 이력")
emu.log("  -> " .. BASE .. "_{ram,vram}.bin · _report.txt")
