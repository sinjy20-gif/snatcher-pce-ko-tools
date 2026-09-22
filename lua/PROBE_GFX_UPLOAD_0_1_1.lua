-- PROBE_GFX_UPLOAD 0.1.1 -- 압축을 푸는 쪽을 잡는다 (2026-08-25)
--
-- 0.1.0 이 알아낸 것
-- ------------------
-- 그림은 **RAM $3B00 버퍼를 거쳐** VRAM 으로 간다.  올리는 코드를 둘 확인했다.
--
--     $71EE  BD 00 3B  LDA $3B00,X -> STA $0002/$0003   CPX #$80  (128 B · 타일 4장)
--     $7263  BD 00 3B  LDA $3B00,X -> STA $0002/$0003   CPX #$20  ( 32 B · 타일 1장)
--     $60AE~ ST1/ST2 즉치 0                              VRAM 지우기 (503k 중 249k)
--
-- (Mesen 은 PC 를 **명령이 끝난 주소**로 준다.  $7269·$71FB 가 `STA $0003` 끝과
--  정확히 맞아떨어져 확인됐다.)
--
-- 0.1.0 은 RAM 을 **끝난 뒤에** 떠서, 그때 $3B00 은 이미 거의 비어 있었다.
-- VRAM 내용도 RAM 에도 디스크에도 없었는데, 버퍼가 작아 흘려보내는 구조라 당연했다.
--
-- 그래서 이 판이 답할 것
-- ----------------------
--     1  누가 $3B00 에 쓰나        그게 압축을 푸는 쪽이다
--     2  그때 무엇을 읽고 있나      제로페이지 포인터를 같이 뜬다
--     3  버퍼에 뭐가 담기나        올리기 직전의 32 B 를 그대로 뜬다
--
-- 1 과 2 가 같이 있어야 "디스크 어디서 왔나" 로 이어진다.
--
-- 쓰는 법
-- -------
--   1) Mesen 에 올린다  (수집기와 같이 올리지 말 것 -- 훅이 섞인다)
--   2) 깁슨 환경 A 컴퓨터 화면을 띄운다
--   3) Stop
--
-- 수집기와 달리 이건 Stop 을 눌러야 보고서가 남는다.

local MEM = emu.memType.pceMemory

local BUF_FROM, BUF_TO = 0x3B00, 0x3B7F   -- 0.1.0 이 찾은 스테이징 버퍼
local ZP_FROM, ZP_TO   = 0x0000, 0x001F   -- 같이 뜰 제로페이지 (포인터가 여기 산다)
local KEEP_SAMPLES     = 24               -- 버퍼 내용을 몇 번이나 뜰까

local stamp = os.date("%Y%m%d_%H%M%S")
local BASE  = "C:\\snatcher\\dump\\gfx_upload_0_1_1_" .. stamp

local writerPcs = {}     -- $3B00 에 쓴 PC -> 횟수
local uploadPcs = {}     -- 버퍼를 VDC 로 올린 PC -> 횟수
local samples   = {}     -- 올리기 직전의 버퍼 스냅샷
local writes, uploads = 0, 0
local frames = 0
local lastSector = -1
local sectors = {}

local function pc_now()
  local ok, s = pcall(emu.getState)
  if not ok or not s then return 0 end
  return s["cpu.pc"] or 0
end

-- ---------------------------------------------------------------- 1) 쓰는 쪽
emu.addMemoryCallback(function(address, value)
  writes = writes + 1
  local pc = pc_now()
  writerPcs[pc] = (writerPcs[pc] or 0) + 1
end, emu.callbackType.write, BUF_FROM, BUF_TO, emu.cpuType.pce, MEM)

-- ---------------------------------------------------------------- 2) 올리는 쪽
--
-- 버퍼에서 읽어 VDC 로 넘기는 순간을 잡는다.  0.1.0 이 찾은 두 자리를 직접 건다 --
-- 범위로 걸면 VRAM 지우기(249k 건)까지 딸려 와 로그가 묻힌다.
local function on_upload()
  uploads = uploads + 1
  local pc = pc_now()
  uploadPcs[pc] = (uploadPcs[pc] or 0) + 1

  -- 앞쪽 몇 번만 버퍼를 통째로 뜬다.  전부 뜨면 수만 건이라 읽을 수가 없다.
  if #samples < KEEP_SAMPLES then
    local buf, zp = {}, {}
    for a = BUF_FROM, BUF_TO do buf[#buf + 1] = emu.read(a, MEM) or 0 end
    for a = ZP_FROM, ZP_TO do zp[#zp + 1] = emu.read(a, MEM) or 0 end
    samples[#samples + 1] = { frame = frames, pc = pc, sector = lastSector,
                              buf = buf, zp = zp }
  end
end

for _, at in ipairs({ 0x71EE, 0x7263 }) do
  emu.addMemoryCallback(on_upload, emu.callbackType.exec, at, at, emu.cpuType.pce, MEM)
end

-- ---------------------------------------------------------------- 섹터 이력
emu.addEventCallback(function()
  frames = frames + 1
  local ok, s = pcall(emu.getState)
  if ok and s then
    local sector = s["cdrom.scsi.sector"]
    if type(sector) == "number" and sector ~= lastSector then
      lastSector = sector
      sectors[#sectors + 1] = { frame = frames, sector = sector }
      if #sectors > 96 then table.remove(sectors, 1) end
    end
  end
  if frames % 1800 == 0 then
    emu.log(string.format("GFX 0.1.1 -- 버퍼쓰기 %d · 업로드 %d · 표본 %d",
                          writes, uploads, #samples))
  end
end, emu.eventType.endFrame)

-- ---------------------------------------------------------------- 보고서
local function hexdump(bytes, origin)
  local out = {}
  for i = 1, #bytes, 16 do
    local row = {}
    for k = i, math.min(i + 15, #bytes) do
      row[#row + 1] = string.format("%02X", bytes[k])
    end
    out[#out + 1] = string.format("    $%04X  %s", origin + i - 1, table.concat(row, " "))
  end
  return table.concat(out, "\n")
end

local function sorted_pcs(map)
  local list = {}
  for pc, n in pairs(map) do list[#list + 1] = { pc = pc, n = n } end
  table.sort(list, function(a, b) return a.n > b.n end)
  return list
end

emu.addEventCallback(function()
  local file = io.open(BASE .. "_report.txt", "w")
  if file == nil then return end

  file:write("PROBE_GFX_UPLOAD 0.1.1  " .. stamp .. "\n")
  file:write(string.format("$%04X-$%04X 쓰기 %d 건 · 업로드 %d 건 · 표본 %d 개\n\n",
                           BUF_FROM, BUF_TO, writes, uploads, #samples))

  if writes == 0 then
    file:write("★ 버퍼에 쓴 것이 없다.  둘 중 하나다:\n")
    file:write("   - 화면을 안 띄웠다\n")
    file:write("   - 버퍼가 $3B00 이 아니다 (다른 화면은 다른 자리를 쓸 수 있다)\n")
    file:write("     그러면 0.1.0 을 다시 돌려 업로더의 LDA 주소를 확인할 것\n\n")
  end

  file:write("-- $3B00 에 쓴 코드 (= 압축 푸는 쪽) --\n")
  for i, e in ipairs(sorted_pcs(writerPcs)) do
    if i > 24 then break end
    file:write(string.format("  $%04X  %d 회\n", e.pc, e.n))
  end

  file:write("\n-- 버퍼를 VDC 로 올린 코드 --\n")
  for i, e in ipairs(sorted_pcs(uploadPcs)) do
    if i > 12 then break end
    file:write(string.format("  $%04X  %d 회\n", e.pc, e.n))
  end

  file:write("\n-- 올리기 직전의 버퍼와 제로페이지 --\n")
  for i, s in ipairs(samples) do
    file:write(string.format("\n[%d] 프레임 %d · PC $%04X · 섹터 %d\n",
                             i, s.frame, s.pc, s.sector))
    file:write("  버퍼 $3B00:\n" .. hexdump(s.buf, BUF_FROM) .. "\n")
    file:write("  제로페이지 $0000:\n" .. hexdump(s.zp, ZP_FROM) .. "\n")
  end

  file:write("\n-- 최근 CD 섹터 --\n")
  for _, e in ipairs(sectors) do
    file:write(string.format("  프레임 %6d  섹터 %d (0x%X)\n", e.frame, e.sector, e.sector))
  end
  file:close()
  emu.log("GFX 0.1.1 보고서 -> " .. BASE .. "_report.txt")
end, emu.eventType.scriptEnded)

emu.log("PROBE_GFX_UPLOAD 0.1.1 -- $3B00 에 쓰는 쪽(압축 해제)을 잡는다")
emu.log("  깁슨 컴퓨터 화면을 띄운 뒤 Stop.  -> " .. BASE .. "_report.txt")
