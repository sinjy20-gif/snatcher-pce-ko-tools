-- PROBE GAUDI QUIZ COMPARE 0.1.0 -- 퀴즈 키워드는 어느 비교기가 보는가.
-- ★순수 관측 · 쓰기 0 B · 화면 오버레이 없음
--
-- 왜 (2026-09-15, 0.7.18 실기)
--   인명 18 개는 통하는데 `천하`(テンカ)·`끝났다`(オワツタ)가 "틀렸다"로 나온다.
--   디스크에 가우디 검색 구현이 **두 벌** 있다:
--
--     논리 $00AD1A6 (CPU $B9E0)  ← 우리 훅이 박힌 인명 비교기
--     논리 $00A13F2               ← 모드바이트·와일드카드가 없는 더 단순한 비교기
--                                   CPU 주소 미상 (정적으로 못 박았다)
--
--   퀴즈 키워드가 뒤엣것을 지나가면 훅이 아예 안 돈다.  그러면 표를 아무리
--   고쳐도 안 통한다 -- 훅을 하나 더 달아야 한다.
--
-- 잡는 것
--   ① 입력 버퍼 $363E-$3660 을 **읽는** PC 와 그때의 MPR5 (= $A000-$BFFF 뱅크)
--   ② 우리 동굴 $BE56 이 실제로 실행되는가
--   PC 별로 접어서 센다.  버퍼 읽기는 수천 번이라 raw 로 쌓으면 못 본다.
--
-- 쓰는 법
--   0.7.18 로드 -> 가우디에서 `천하` 입력 -> 결정 -> Stop
--   (인명 하나도 같이 쳐 두면 대조군이 생긴다 -- 그건 $B9E0 이 잡혀야 정상)
--
-- 산출물  C:/snatcher/dump/gaudi_quiz_compare_v010.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local OUT = "C:/snatcher/dump/gaudi_quiz_compare_v010.tsv"
local LO, HI = 0x363E, 0x3660
local CAVE = 0xBE56

local seen = {}      -- "PC|MPR5" -> {pc, mpr, n, firstFrame, sample}
local caveHits = 0
local caveFirst = -1

local function rb(at) return emu.read(at % 0x10000, MEM) or 0 end

local function st()
  local ok, s = pcall(emu.getState)
  return (ok and s) or {}
end

local function frame()
  local s = st()
  return s["ppu.frameCount"] or s["frameCount"] or 0
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
  local s = st()
  local pc = (s["cpu.pc"] or 0) % 0x10000
  local mpr = (s["memoryManager.mpr[5]"] or -1) % 256
  local key = string.format("%04X|%02X", pc, mpr)
  local e = seen[key]
  if e then
    e.n = e.n + 1
  else
    seen[key] = { pc = pc, mpr = mpr, n = 1, f = frame(), sample = buf() }
  end
end, emu.callbackType.read, LO, HI, CPU, MEM)

emu.addMemoryCallback(function()
  caveHits = caveHits + 1
  if caveFirst < 0 then caveFirst = frame() end
end, emu.callbackType.exec, CAVE, CAVE, CPU, MEM)

local function dump()
  local f = io.open(OUT, "w")
  if not f then return end
  f:write("-- PROBE GAUDI QUIZ COMPARE 0.1.0\n")
  f:write(string.format("-- 동굴 $%04X 실행 %d 회 (첫 프레임 %s)\n",
    CAVE, caveHits, caveFirst >= 0 and tostring(caveFirst) or "없음"))
  f:write("pc\tmpr5\treads\tfirst_frame\tbuffer_sample\n")
  local list = {}
  for _, e in pairs(seen) do list[#list + 1] = e end
  table.sort(list, function(a, b) return a.n > b.n end)
  for _, e in ipairs(list) do
    f:write(string.format("$%04X\t$%02X\t%d\t%d\t%s\n", e.pc, e.mpr, e.n, e.f, e.sample))
  end
  f:close()
end

emu.addEventCallback(dump, emu.eventType.scriptEnded)
emu.addEventCallback(dump, emu.eventType.stateLoaded)
