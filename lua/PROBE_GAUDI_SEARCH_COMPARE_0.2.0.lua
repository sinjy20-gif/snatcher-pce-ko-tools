-- PROBE GAUDI SEARCH COMPARE 0.2.0 -- 최종 비교에서 무엇과 무엇을 재는가.
-- ★순수 관측 · 쓰기 0 B
--
-- 0.1.0 이 알려준 것 (2026-09-14, 0.7.13)
--   훅은 정상이다.  `길리언`(イシノ) -> `ギリアン` 로 정확히 바뀐다.
--   그런데 `제이미` 도 똑같이 바뀌는데 한쪽만 검색된다.
--   둘 다 나중에 게임이 **원래 입력 길이로 FF 를 다시 꽂아** 한 글자씩 잘린다
--   (`ギリアン`->`ギリア`, `ジエミー`->`ジエミ`).  그래서 자르기가 원인인지
--   결과인지 가려야 한다.
--
-- 여기서 찍는 것
--   `$BA00` / `$BA19` 비교 진입마다
--     · 입력 버퍼 $363E (FF 까지)
--     · 제로페이지 $D4:$D5 -> 후보 문자열 CPU $C000+그 값
--     · 후보 바이트 (FF 까지)
--   되는 이름과 안 되는 이름을 나란히 놓으면 어디서 갈리는지 바로 보인다.
--
-- 쓰는 법  로드 -> `길리언` 검색 -> `제이미` 검색 -> Stop
-- 산출물   C:/snatcher/dump/gaudi_search_compare_v020.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local OUT = "C:/snatcher/dump/gaudi_search_compare_v020.tsv"
local INPUT, ZP = 0x363E, 0x2000
local rows, n = {}, 0
local MAX = 600

local function rb(at) return emu.read(at % 0x10000, MEM) or 0 end
local function st()
  local ok, s = pcall(emu.getState)
  return (ok and s) or {}
end
local function str(at, limit)
  local t = {}
  for i = 0, limit - 1 do
    local b = rb(at + i)
    t[#t + 1] = string.format("%02X", b)
    if b == 0xFF then break end
  end
  return table.concat(t, " ")
end

local function hit(where)
  return function()
    if n >= MAX then return end
    n = n + 1
    local s = st()
    local d = rb(ZP + 0xD4) | (rb(ZP + 0xD5) << 8)
    local cand = 0xC000 + (d & 0x1FFF)
    rows[#rows + 1] = string.format("%d\t%s\t$%04X\t$%04X\t%s\t%s",
      n, where, d, cand, str(INPUT, 20), str(cand, 20))
  end
end

emu.addMemoryCallback(hit("BA00"), emu.callbackType.exec, 0xBA00, 0xBA00, CPU, MEM)
emu.addMemoryCallback(hit("BA19"), emu.callbackType.exec, 0xBA19, 0xBA19, CPU, MEM)

emu.addEventCallback(function()
  local f = assert(io.open(OUT, "w"))
  f:write("n\twhere\td4d5\tcand_cpu\tinput\tcandidate\n")
  for _, r in ipairs(rows) do f:write(r .. "\n") end
  f:close()
  emu.log(string.format("GAUDI SEARCH COMPARE 0.2.0 -> %s  (%d 건)", OUT, #rows))
end, emu.eventType.scriptEnded)

emu.log("PROBE GAUDI SEARCH COMPARE 0.2.0 loaded -- 길리언 · 제이미 순서로 검색하고 Stop")
