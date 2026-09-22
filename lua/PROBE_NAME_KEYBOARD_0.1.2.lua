-- PROBE 이름자판 0.1.2 -- 대응표의 CPU 주소와 선두 바이트($83)가 나오는 자리
--
-- 지금까지 나온 것 (0.1.1 + 정적 탐색, 인계서 §8-Y)
-- ---------------------------------------------------------------------------
--   입력 버퍼   $363E 부터 2 바이트씩 전진
--   입력 루틴   PC $BC0A 가 거기에 쓴다
--   대응표      디스크 0xB930A / 0xC6DB2 에 두 벌.  SJIS **후속 바이트만** 담는다
--                 41 43 45 47 49 01 4A 4C 4E 50 52 01 …   (01 = 5칸 묶음 구분, 00 = 줄 끝)
--               선두 $83 은 코드가 붙인다 -- 그 자리를 아직 못 찾았다
--
-- 이 프로브가 답할 것
-- ---------------------------------------------------------------------------
--   1) 대응표가 **CPU 주소 어디에** 올라와 있는가.  그래야 어느 뱅크를 고칠지 정해진다
--   2) 그 순간 MPR 이 어떻게 걸려 있는가 (뱅크 식별)
--   3) 쓰는 PC 주변 코드 32 바이트.  `A9 83` (LDA #$83) 가 보이면 그 자리가 답이다
--
-- 값비싼 일은 **첫 가타카나 입력 한 번만** 한다.  그 뒤로는 0.1.1 처럼 가볍게 센다.
--
-- 돌리는 법
-- ---------------------------------------------------------------------------
--   가우디 -> 인물 파일 -> 인명검색 에서 아무 키나 **한 번** 누르면 바로 찍힌다.
--   두세 개 더 눌러도 좋다.  그 다음 Stop.

local OUT = "C:\\snatcher\\dump\\probe_name_keyboard_v012.tsv"
local mem = emu.memType.pceMemory

local BUF_LO, BUF_HI = 0x3630, 0x3670        -- 입력 버퍼 언저리만 본다 (0.1.1 은 RAM 전체였다)
local PATTERN = { 0x41, 0x43, 0x45, 0x47, 0x49, 0x01, 0x4A, 0x4C, 0x4E, 0x50, 0x52 }

local file = assert(io.open(OUT, "w"))
file:write("kind\tframe\tpc\taddr\tvalue\tdetail\n")

local frame = 0
local rows  = 0
local scanned = false
local pendPc, pendAddr, pendValue = nil, 0, 0
local census = {}

local function byte(a) return emu.read(a, mem) or 0 end

local function row(kind, pc, addr, value, detail)
  rows = rows + 1
  file:write(string.format("%s\t%d\t%04X\t%04X\t%02X\t%s\n",
    kind, frame, pc or 0, addr or 0, value or 0, detail or ""))
  file:flush()
end

local function state()
  local ok, s = pcall(emu.getState)
  if ok and s then return s end
  return nil
end

local function pcOf(s)
  if s == nil then return 0 end
  return s["cpu.pc"] or s["pc"] or 0
end

local function mprText(s)
  if s == nil then return "-" end
  local out = {}
  for slot = 0, 7 do
    local v = s[string.format("memoryManager.mpr[%d]", slot)]
    if v == nil then v = s[string.format("mpr[%d]", slot)] end
    out[#out + 1] = string.format("%02X", v or 0)
  end
  return table.concat(out, " ")
end

local function hexRange(from, n)
  local t = {}
  for i = 0, n - 1 do t[#t + 1] = string.format("%02X", byte(from + i)) end
  return table.concat(t, " ")
end

-- 대응표가 CPU 공간 어디에 있는지 찾는다.  한 번만 돈다.
local function findTable()
  local first = PATTERN[1]
  for base = 0x2000, 0xFFF0 do
    if byte(base) == first then
      local ok = true
      for i = 2, #PATTERN do
        if byte(base + i - 1) ~= PATTERN[i] then ok = false; break end
      end
      if ok then return base end
    end
  end
  return nil
end

emu.addMemoryCallback(function(address, value)
  if pendPc ~= nil then
    if address == pendAddr + 1 then
      local ch = string.format("%02X %02X", pendValue, value)
      census[pendPc] = (census[pendPc] or 0) + 1
      row("input", pendPc, pendAddr, pendValue, "문자 " .. ch)

      if not scanned then
        scanned = true
        local s = state()
        row("mpr", pcOf(s), 0, 0, "MPR " .. mprText(s))
        row("code", pendPc, 0, 0, "PC-16 부터 48B: " .. hexRange((pendPc - 16) % 0x10000, 48))

        local t = findTable()
        if t then
          row("table", 0, t, 0, "대응표 CPU 주소 발견: " .. hexRange(t, 24))
        else
          row("table", 0, 0, 0, "CPU 공간에서 대응표를 못 찾았다 -- 뱅크가 안 걸려 있다")
        end
        row("buf", 0, BUF_LO, 0, "$363E 부터 32B: " .. hexRange(0x363E, 32))
      end
      pendPc = nil
      return
    end
    pendPc = nil
  end

  if value == 0x83 then
    local s = state()
    pendPc    = pcOf(s)
    pendAddr  = address
    pendValue = value
  end
end, emu.callbackType.write, BUF_LO, BUF_HI, emu.cpuType.pce, mem)

emu.addEventCallback(function() frame = frame + 1 end, emu.eventType.endFrame)

emu.addEventCallback(function()
  for pc, n in pairs(census) do
    row("census", pc, 0, 0, string.format("이 PC 가 %d 회 썼다", n))
  end
  file:write(string.format("-- 총 %d 행\n", rows))
  file:close()
end, emu.eventType.scriptEnded)

emu.log("PROBE 이름자판 0.1.2 -- 대응표 CPU 주소 · MPR · PC 주변 코드")
emu.log("  인명검색 자판에서 키를 한 번만 눌러도 바로 찍힌다.  두세 개 더 눌러도 좋다")
emu.log("  code 행에서 A9 83 (LDA #$83) 을 찾을 것 -- 그 자리가 선두 바이트다")
emu.log("  출력: " .. OUT)
