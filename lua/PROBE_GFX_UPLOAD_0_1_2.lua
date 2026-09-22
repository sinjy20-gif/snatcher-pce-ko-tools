-- PROBE_GFX_UPLOAD 0.1.2 -- 소스가 어디 있는지 잡는다 (2026-08-25)
--
-- 0.1.1 이 알아낸 것
-- ------------------
-- $3B00 버퍼에 쓰는 쪽이 **압축 해제가 아니라 비트플레인 변환**이었다.
--
--     $71B8  STA $3B00,X                 <- PC $71BB  6,145 회
--     $71D1  LDA ($14),Y                 ★ 소스 포인터는 제로페이지 $14/$15
--     $71D3  ASL A / ROL $3B60,X / ROL A / ROL $3B40,X
--            / ROL A / ROL $3B20,X / ROL A / ROL $3B00,X
--            = 한 바이트의 비트를 플레인 4 장에 나눠 꽂는다
--
--     $7220  STA $3B00,X                 <- PC $7223  17,824 회
--     $7203~ (LSR A / ROL $07) x8        = 비트 역순 (가로 뒤집기)
--     $723B  LDA ($14),Y                 ★ 같은 포인터
--
-- 그래서 **디스크 데이터는 PCE 플레인 형식이 아니다.**  올리면서 만든다.
-- 바이트 순서를 여섯 가지로 바꿔 가며 디스크를 뒤져도 안 나온 이유가 이것이다 --
-- 순서 문제가 아니라 형식이 다른 것이었다.
--
-- 0.1.1 의 구멍 둘
-- ----------------
--     제로페이지를 $0000 에서 읽었다.  PCE 는 거기가 하드웨어 페이지라 전부 FF 다.
--     진짜 제로페이지는 **$2000** 이다.  포인터를 한 개도 못 건졌다.
--
--     끝난 뒤에 읽어 봐야 이미 초기화돼 있다 (($14) = $001B 였다).
--     읽는 **그 순간**을 잡아야 한다.
--
-- 그래서 이 판이 답할 것
-- ----------------------
--     1  ($14) 가 어디를 가리키나        읽는 순간의 값
--     2  그 자리에 무엇이 있나            거기서 64 B 를 그대로 뜬다
--     3  어느 뱅크인가                    MPR 을 같이 뜬다.  포인터가 $6000 대면
--                                         뱅크를 알아야 디스크와 맞출 수 있다
--
-- 이 셋이 있으면 디스크에서 그 바이트를 찾아 원본 위치가 확정된다.
--
-- 쓰는 법
-- -------
--   1) Mesen 에 올린다  (수집기·다른 프로브와 같이 올리지 말 것)
--   2) 깁슨 환경 A 컴퓨터 화면을 띄운다
--   3) Stop

local MEM = emu.memType.pceMemory

local ZP        = 0x2000        -- ★ PCE 의 진짜 제로페이지.  $0000 이 아니다
local READ_SITES = { 0x71D1, 0x723B }   -- LDA ($14),Y 두 자리
local PEEK      = 64            -- 포인터 자리에서 몇 바이트나 뜰까
local KEEP      = 32            -- 표본 몇 개나 남길까

local stamp = os.date("%Y%m%d_%H%M%S")
local BASE  = "C:\\snatcher\\dump\\gfx_upload_0_1_2_" .. stamp

local samples  = {}
local pointers = {}      -- 본 포인터 값 -> 횟수
local reads    = 0
local frames   = 0
local lastSector = -1
local sectors  = {}

local function mprs()
  local ok, s = pcall(emu.getState)
  if not ok or not s then return "?" end
  local out = {}
  for i = 0, 7 do
    local v = s["memoryManager.mpr[" .. i .. "]"]
    out[#out + 1] = type(v) == "number" and string.format("%02X", v) or "??"
  end
  return table.concat(out, " ")
end

local function on_read()
  reads = reads + 1
  local low  = emu.read(ZP + 0x14, MEM) or 0
  local high = emu.read(ZP + 0x15, MEM) or 0
  local ptr  = low | (high << 8)
  pointers[ptr] = (pointers[ptr] or 0) + 1

  -- 표본은 앞쪽 몇 개만.  이 훅은 2 만 번 넘게 돈다 -- 전부 뜨면 못 읽는다.
  if #samples >= KEEP then return end
  local bytes = {}
  for i = 0, PEEK - 1 do bytes[#bytes + 1] = emu.read((ptr + i) & 0xFFFF, MEM) or 0 end
  local ok, s = pcall(emu.getState)
  samples[#samples + 1] = {
    frame = frames, ptr = ptr, sector = lastSector, mpr = mprs(),
    y = ok and s and (s["cpu.y"] or 0) or 0,
    pc = ok and s and (s["cpu.pc"] or 0) or 0,
    bytes = bytes,
  }
end

for _, at in ipairs(READ_SITES) do
  emu.addMemoryCallback(on_read, emu.callbackType.exec, at, at, emu.cpuType.pce, MEM)
end

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
    emu.log(string.format("GFX 0.1.2 -- 소스 읽기 %d · 표본 %d · 서로 다른 포인터 %d",
                          reads, #samples, (function()
                            local n = 0; for _ in pairs(pointers) do n = n + 1 end; return n
                          end)()))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  local file = io.open(BASE .. "_report.txt", "w")
  if file == nil then return end
  file:write("PROBE_GFX_UPLOAD 0.1.2  " .. stamp .. "\n")
  file:write(string.format("소스 읽기 %d 건 · 표본 %d 개\n\n", reads, #samples))

  if reads == 0 then
    file:write("★ 한 건도 안 잡혔다.  $71D1/$723B 를 안 지나갔다는 뜻이다.\n")
    file:write("   0.1.1 을 다시 돌려 이번 화면의 writer PC 부터 확인할 것.\n\n")
  end

  file:write("-- 본 포인터 값 (많은 순) --\n")
  local list = {}
  for ptr, n in pairs(pointers) do list[#list + 1] = { ptr = ptr, n = n } end
  table.sort(list, function(a, b) return a.n > b.n end)
  for i = 1, math.min(#list, 24) do
    file:write(string.format("  $%04X  %d 회\n", list[i].ptr, list[i].n))
  end

  file:write("\n-- 표본 (읽는 순간의 포인터 자리) --\n")
  for i, s in ipairs(samples) do
    file:write(string.format("\n[%d] 프레임 %d · PC $%04X · ($14)=$%04X · Y=$%02X · 섹터 %d\n",
                             i, s.frame, s.pc, s.ptr, s.y, s.sector))
    file:write("    MPR: " .. s.mpr .. "\n")
    for k = 1, #s.bytes, 16 do
      local row = {}
      for j = k, math.min(k + 15, #s.bytes) do
        row[#row + 1] = string.format("%02X", s.bytes[j])
      end
      file:write(string.format("    $%04X  %s\n", (s.ptr + k - 1) & 0xFFFF, table.concat(row, " ")))
    end
  end

  file:write("\n-- 최근 CD 섹터 --\n")
  for _, e in ipairs(sectors) do
    file:write(string.format("  프레임 %6d  섹터 %d (0x%X)\n", e.frame, e.sector, e.sector))
  end
  file:close()
  emu.log("GFX 0.1.2 보고서 -> " .. BASE .. "_report.txt")
end, emu.eventType.scriptEnded)

emu.log("PROBE_GFX_UPLOAD 0.1.2 -- 소스 포인터 ($14) 를 읽는 순간에 잡는다")
emu.log("  깁슨 컴퓨터 화면을 띄운 뒤 Stop.  -> " .. BASE .. "_report.txt")
