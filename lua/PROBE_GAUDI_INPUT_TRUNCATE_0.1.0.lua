-- PROBE GAUDI INPUT TRUNCATE 0.1.0 -- 누가 입력 버퍼를 다시 자르는가.
-- ★순수 관측 · 쓰기 0 B
--
-- 왜 (2026-09-14, 0.7.13 실측)
--   훅은 정상이다.  `길리언`(イシノ) -> `ギリアン` 로 정확히 바뀐다.
--   그런데 게임이 **원래 입력 길이**로 `FF` 를 다시 꽂아 뒤를 날린다.
--     ギリアン -> ギリア · ギブスン -> ギブ · ジエミー -> ジエミ · ハリー -> ハリ
--   4 번째 글자가 `ー`($81 5B)로 시작하는 이름만 우연히 살아남았다
--   (제이미·해리).  `ン`($83 93)처럼 $83 으로 시작하면 비교가 이어져서 떨어진다.
--
--   그러니 자르는 자리를 찾아 **길이 변수**를 같이 고치면 18 개가 한 번에 풀린다.
--   동굴 여유가 22 B 뿐이라 우회 코드(35~40 B)보다 이쪽이 훨씬 싸다.
--
-- 잡는 것
--   입력 버퍼 $363E-$3660 에 대한 **쓰기**마다 PC·값·주소.
--   특히 `$FF` 를 쓰는 자리가 자르는 놈이다.
--   그 PC 주변을 역어셈블하면 길이가 어느 변수에서 오는지 보인다.
--
-- 쓰는 법  로드 -> `길리언` 검색 -> Stop
-- 산출물   C:/snatcher/dump/gaudi_input_truncate_v010.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local OUT = "C:/snatcher/dump/gaudi_input_truncate_v010.tsv"
local LO, HI = 0x363E, 0x3660
local rows, n = {}, 0
local MAX = 800

local function rb(at) return emu.read(at % 0x10000, MEM) or 0 end
local function st()
  local ok, s = pcall(emu.getState)
  return (ok and s) or {}
end
local function buf()
  local t = {}
  for i = 0, 15 do
    local b = rb(LO + i)
    t[#t + 1] = string.format("%02X", b)
    if b == 0xFF then break end
  end
  return table.concat(t, " ")
end

emu.addMemoryCallback(function(address, value)
  if n >= MAX then return end
  n = n + 1
  local s = st()
  rows[#rows + 1] = string.format("%d\t$%04X\t$%02X\t$%04X\t$%02X\t$%02X\t%s",
    n, address, value,
    (s["cpu.pc"] or 0) % 0x10000,
    (s["memoryManager.mpr[5]"] or -1) % 256,
    (s["cpu.y"] or -1) % 256,
    buf())
end, emu.callbackType.write, LO, HI, CPU, MEM)

emu.addEventCallback(function()
  local f = assert(io.open(OUT, "w"))
  f:write("n\taddr\tvalue\tpc\tmpr5\ty\tbuffer_before\n")
  for _, r in ipairs(rows) do f:write(r .. "\n") end
  f:close()
  local ff = 0
  for _, r in ipairs(rows) do if r:find("\t%$FF\t") then ff = ff + 1 end end
  emu.log(string.format("GAUDI INPUT TRUNCATE 0.1.0 -> %s  (쓰기 %d · 그중 $FF %d)", OUT, #rows, ff))
end, emu.eventType.scriptEnded)

emu.log("PROBE GAUDI INPUT TRUNCATE 0.1.0 loaded -- 길리언 검색하고 Stop")
