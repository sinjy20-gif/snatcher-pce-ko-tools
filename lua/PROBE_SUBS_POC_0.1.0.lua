-- PROBE 자막 POC 0.1.0 -- 로더가 어디서 멈추는가
--
-- 증상: 게임은 정상, 자막이 안 뜬다.  로더 사슬 어디서 끊겼는지 단계별로 짚는다.
--
-- 사슬 (0.3.13-bios-poc 기준.  helper_symbols.json 에서 확인한 값)
-- ---------------------------------------------------------------------------
--     $7D10   스텁 출구.  JMP $7F4C
--     $7F4C   로더 진입
--     $7F51   벡터가 이미 우리 것이면 $7F9C 로 (설치 완료 상태)
--     $7F6F   TAI $1A00 -> $5C40, 245 B   엔진만 먼저
--     $7F76   서명 검사 시작.  $5C40 이 $48(PHA) 인가
--     $7F84   검사 통과.  여기부터 패턴·SAT + 벡터
--     $5C40   설치된 IRQ 훅 진입
--
-- 각 지점에 걸어서 **어디까지 갔는지** 본다.  그리고 $7F76 시점에 $5C40 에 실제로
-- 무엇이 들어왔는지 찍는다 -- AC 가 안 올라와 있으면 쓰레기가 보일 것이다.
--
-- ★ 뱅크 확인.  $7Fxx 는 MPR3=$69 일 때만 케이브다.  다른 뱅크면 전혀 다른 코드다.
--   (CD 드라이버를 $C000 으로 본 실수가 이 확인을 안 해서 나왔다.)
--
-- 돌리는 법
-- ---------------------------------------------------------------------------
--   build/patch/EXPERIMENT/0.3.13-bios-poc/...cue
--   타이틀에서 오프닝까지 보고 Stop.

local OUT = "C:\\snatcher\\dump\\probe_subs_poc_0_1_0.tsv"
local mem = emu.memType.pceMemory

local STUB_EXIT = 0x7D10
local LOADER    = 0x7F4C
local SIGCHECK  = 0x7F76
local PASSED    = 0x7F84
local IRQHOOK   = 0x5C40
local CAVE_BANK = 0x69

local file = assert(io.open(OUT, "w"))
file:write("kind\tframe\tcount\tmpr3\tdetail\tnote\n")

local frame, rows = 0, 0
local n = {stub=0, loader=0, sig=0, passed=0, irq=0, wrongbank=0}
local first = {}
local LOG = 3

local function byte(a) return emu.read(a, mem) or 0 end

local function mpr3()
  local ok, s = pcall(emu.getState)
  if not ok or s == nil then return -1 end
  local v = s["memoryManager.mpr[3]"]
  if v == nil then v = s["mpr[3]"] end
  return v or -1
end

local function row(kind, count, m3, detail, note)
  rows = rows + 1
  file:write(string.format("%s\t%d\t%d\t%s\t%s\t%s\n", kind, frame, count,
    m3 >= 0 and string.format("%02X", m3) or "", detail or "", note or ""))
end

local function hook(addr, key, note, detail)
  emu.addMemoryCallback(function()
    local m3 = mpr3()
    if addr >= 0x6000 and addr < 0x8000 and m3 ~= CAVE_BANK then
      n.wrongbank = n.wrongbank + 1
      if n.wrongbank <= 2 then row("wrongbank", n.wrongbank, m3, key, "케이브가 아닌 뱅크") end
      return
    end
    n[key] = n[key] + 1
    if first[key] == nil then first[key] = frame end
    if n[key] <= LOG then
      row(key, n[key], m3, detail and detail() or "", note)
    end
  end, emu.callbackType.exec, addr, addr, emu.cpuType.pce, mem)
end

hook(STUB_EXIT, "stub",   "스텁 출구 -> 로더로 JMP")
hook(LOADER,    "loader", "로더 진입", function()
  return string.format("$2202=%02X%02X", byte(0x2203), byte(0x2202))
end)
hook(SIGCHECK,  "sig",    "서명 검사.  $5C40 에 무엇이 왔나", function()
  local t = {}
  for i = 0, 7 do t[#t+1] = string.format("%02X", byte(0x5C40 + i)) end
  return "5C40: " .. table.concat(t, " ") .. "  (기대 48 EE 31 5D)"
end)
hook(PASSED,    "passed", "★ 검사 통과 -- 패턴·SAT 로 간다")
hook(IRQHOOK,   "irq",    "★ IRQ 훅이 돈다")

emu.addEventCallback(function() frame = frame + 1 end, emu.eventType.endFrame)

emu.addEventCallback(function()
  row("vector", 0, -1, string.format("$2202=%02X%02X", byte(0x2203), byte(0x2202)),
      "끝났을 때의 IRQ1 벡터.  5C40 이면 설치됨")
  local verdict
  if n.stub == 0 then      verdict = "★ 스텁 출구조차 안 왔다 -- 패치본이 맞는지 확인"
  elseif n.loader == 0 then verdict = "★ 스텁은 왔는데 로더로 안 갔다 -- JMP 주소가 틀렸다"
  elseif n.sig == 0 then    verdict = "★ 로더는 왔는데 서명 검사에 못 갔다 -- 벡터 검사에서 다 빠졌다"
  elseif n.passed == 0 then verdict = "★ 서명 검사에서 전부 탈락 -- AC 가 안 올라왔다.  sig 행의 바이트를 볼 것"
  elseif n.irq == 0 then    verdict = "★ 설치는 됐는데 IRQ 훅이 안 돈다 -- 벡터를 게임이 되돌렸을 수 있다"
  else                      verdict = "사슬은 다 돈다 -- 그리기 쪽 문제다"
  end
  row("verdict", 0, -1, "", verdict)
  file:write(string.format(
    "-- 프레임 %d · 스텁 %d · 로더 %d · 서명 %d · 통과 %d · IRQ %d · 뱅크틀림 %d\n",
    frame, n.stub, n.loader, n.sig, n.passed, n.irq, n.wrongbank))
  file:close()
end, emu.eventType.scriptEnded)

emu.log("PROBE 자막 POC 0.1.0 -- 로더 사슬 어디서 끊기나")
emu.log("  0.3.13-bios-poc 로 돌릴 것.  타이틀 -> 오프닝 보고 Stop")
emu.log("  sig 행의 $5C40 바이트가 핵심.  48 EE 31 5D 면 AC 가 올라온 것")
emu.log("  verdict 행이 답이다")
emu.log("  출력: " .. OUT)
