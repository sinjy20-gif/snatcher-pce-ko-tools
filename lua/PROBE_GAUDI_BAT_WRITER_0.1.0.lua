-- PROBE GAUDI BAT WRITER 0.1.0 -- 누가 자판 타일맵을 쓰는가.  ★순수 관측 · 쓰기 0 B
--
-- 왜 이걸 보나
--   자판 글자 타일은 디스크 블록으로 확인됐다 (타일 $200 부터 129 장, 사본 4).
--   못 정한 것은 **배치**다.  45 키 중 셋(메·슈·천)이 다른 키와 타일 반쪽을
--   나눠 쓰므로, 45 자를 다 맞추려면 타일맵 3 칸을 바꿔야 한다.
--   그 3 칸이 디스크 데이터면 제자리 치환으로 끝나고, 코드가 쓰는 것이면
--   코드를 고쳐야 한다.  풀린 바이트로 디스크를 뒤지는 것은 답이 안 된다 --
--   타일맵도 압축돼 있으면 그 바이트가 디스크에 그대로 있을 리 없기 때문이다.
--
-- 어떻게
--   PCE 는 VRAM 을 VDC 포트로만 쓴다.  $0000 = 레지스터 선택, $0002/$0003 = 데이터.
--   레지스터 $00 은 MAWR(쓸 주소), $02 는 VWR(데이터)다.  $0003 에 상위 바이트가
--   실릴 때 한 워드가 써지고 주소가 1 늘어난다.  그 주소를 따라가다가 자판 칸에
--   닿는 순간의 PC 와 뱅크를 찍는다.
--
-- 노리는 칸 (VRAM 워드 주소 = 행*64 + 열)
--   (34,20) $0894   (35,16) $08D0   (36,4) $0904     <- 반쪽을 나눠 쓰는 셋
--   자판 전체는 행 33~38, 열 3~28
--
-- 쓰는 법  로드 -> 가우디 검색 자판에 **들어갔다가 한 번 나오고** -> Stop
-- 산출물   C:/snatcher/dump/gaudi_bat_writer_v010.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local OUT = "C:/snatcher/dump/gaudi_bat_writer_v010.tsv"
local BAT_W = 64
local ROW_LO, ROW_HI, COL_LO, COL_HI = 33, 38, 3, 28
local SHARED = { [34 * BAT_W + 20] = true, [35 * BAT_W + 16] = true, [36 * BAT_W + 4] = true }

local frame, reg, mawr, rows, stateKeys = 0, -1, -1, {}, nil
local lowByte = 0
local MAX = 4000

local function st()
  local ok, s = pcall(emu.getState)
  return (ok and s) or {}
end
local function pick(s, ...)
  for _, k in ipairs({ ... }) do
    if s[k] ~= nil then return s[k] end
  end
  return -1
end

emu.addEventCallback(function() frame = frame + 1 end, emu.eventType.startFrame)

local function note(addr, value)
  if #rows >= MAX then return end
  local row, col = addr // BAT_W, addr % BAT_W
  if row < ROW_LO or row > ROW_HI or col < COL_LO or col > COL_HI then return end
  local s = st()
  if not stateKeys then
    stateKeys = {}
    for k in pairs(s) do stateKeys[#stateKeys + 1] = k end
    table.sort(stateKeys)
    emu.log("state keys: " .. table.concat(stateKeys, " "))
  end
  rows[#rows + 1] = string.format("%d\t%d\t%d\t$%04X\t$%04X\t%s\t$%02X\t$%02X",
    frame, row, col, addr, value,
    SHARED[addr] and "SHARED" or "-",
    pick(s, "cpu.mpr3", "mpr3", "cpu.mpr.3") % 256,
    pick(s, "cpu.mpr5", "mpr5", "cpu.mpr.5") % 256)
  rows[#rows] = rows[#rows] .. string.format("\t$%04X", pick(s, "cpu.pc", "pc") % 65536)
end

emu.addMemoryCallback(function(address, value)
  local port = address & 3
  if port == 0 then
    reg = value & 0x1F
  elseif port == 2 then
    lowByte = value
    if reg == 0 then mawr = (mawr & 0xFF00) | value end
  elseif port == 3 then
    if reg == 0 then
      mawr = ((value << 8) | (mawr & 0xFF)) & 0xFFFF
    elseif reg == 2 and mawr >= 0 then
      note(mawr, ((value << 8) | lowByte) & 0xFFFF)
      mawr = (mawr + 1) & 0xFFFF
    end
  end
end, emu.callbackType.write, 0x0000, 0x0003, CPU, MEM)

emu.addEventCallback(function()
  local f = assert(io.open(OUT, "w"))
  f:write("frame\trow\tcol\tvram_word\tvalue\tshared\tmpr3\tmpr5\tpc\n")
  for _, r in ipairs(rows) do f:write(r .. "\n") end
  f:close()
  local shared = 0
  for _, r in ipairs(rows) do if r:find("SHARED") then shared = shared + 1 end end
  emu.log(string.format("GAUDI BAT WRITER 0.1.0 -> %s  (자판 칸 쓰기 %d 건 · 공유 칸 %d 건)",
    OUT, #rows, shared))
  if #rows == 0 then
    emu.log("0 건이면 타일맵이 VDC 포트가 아니라 DMA 로 올라간다는 뜻이다 (VDC reg $12 SATB/블록전송).")
  end
end, emu.eventType.scriptEnded)

emu.log("PROBE GAUDI BAT WRITER 0.1.0 loaded -- 자판에 들어갔다 나오고 Stop")
