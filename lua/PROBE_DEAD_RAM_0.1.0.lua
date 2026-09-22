-- PROBE 죽은 RAM 0.1.0 -- 자막 엔진이 상주할 자리를 찾는다
--
-- 왜 여기여야 하나
-- ---------------------------------------------------------------------------
-- PROBE_OPENING_HOOK_0.1.1 이 뜬 MPR 을 전부 겹치면 이렇게 나온다:
--
--     MPR0  FF  항상        I/O
--     MPR1  F8  항상        $2000-$3FFF  베이스 RAM
--     MPR2  68  항상        $4000-$5FFF  ($40A4 가 여기 산다)
--     MPR3  69/6A           바뀜
--     MPR4~6                심하게 바뀜  (6B 00 6D 85 74 86 71 82 ...)
--     MPR7  00  항상        BIOS
--
-- IRQ 는 아무 문맥에서나 걸린다.  그러므로 **프레임 훅은 항상 매핑된 창에만**
-- 둘 수 있다 -- MPR1 이나 MPR2.  헬퍼 케이브($BCD2)는 MPR5 창이라 **못 쓴다.**
-- 크기로는 들어가지만(POC 훅 64 B < 잔여 87 B) 자리가 틀렸다.
--
-- 케이브 64 B 예약은 여전히 유효하다.  AC->RAM 로더는 컷신 진입 시점에
-- **알려진 문맥에서** 불리므로 창이 보장된다.  엔진 본체와 훅만 옮기면 된다.
--
-- 그래서 이 프로브는 $2200-$3FFF (제로페이지·스택 뺀 베이스 RAM 7.5 KB) 에서
-- 오프닝 내내 **한 번도 안 쓰이는 구간**을 찾는다.
--
-- 필요한 크기
-- ---------------------------------------------------------------------------
--     POC 훅          64 B      이것만 되면 자막이 화면에 뜬다
--     엔진 전체    1,140 B      패턴버퍼 576 + 인터프리터 300 + SAT 128 + 나머지
--
-- 읽는 법
-- ---------------------------------------------------------------------------
--   run 행이 후보다.  64 B 이상이면 POC 가 되고, 1,140 B 이상이면 엔진이 들어간다.
--   여러 조각으로 흩어져 있어도 된다 -- 버퍼와 코드를 나눠 놓으면 그만이다.
--
-- 주의: "안 쓰였다" 는 이 실행에서 그랬다는 뜻이다.  다른 장면이 쓸 수 있으므로
--       후보가 나오면 대화·메뉴·세이브 장면에서도 같은 프로브를 돌려 교차 확인할 것.
--
-- 돌리는 법
-- ---------------------------------------------------------------------------
--   오프닝을 끝까지 두고 Stop.  약 133 초.

local OUT = "C:\\snatcher\\dump\\probe_dead_ram_0_1_0.tsv"
local mem = emu.memType.pceMemory

local LO, HI = 0x2200, 0x3FFF
local NEED_POC, NEED_ENGINE = 64, 1140

local file = assert(io.open(OUT, "w"))
file:write("kind\tframe\tstart\tsize\tnote\n")

local frame, rows = 0, 0
local touched = {}
local writes = 0

local function row(kind, a, b, note)
  rows = rows + 1
  file:write(string.format("%s\t%d\t%s\t%s\t%s\n", kind, frame,
    tostring(a or ""), tostring(b or ""), note or ""))
end

-- 콜백은 최대한 가볍게.  여기서 무거운 일을 하면 예산을 다 먹는다 (0.1.x 교훈)
emu.addMemoryCallback(function(address)
  touched[address] = true
  writes = writes + 1
end, emu.callbackType.write, LO, HI, emu.cpuType.pce, mem)

emu.addEventCallback(function() frame = frame + 1 end, emu.eventType.endFrame)

emu.addEventCallback(function()
  local runs = {}
  local start = nil
  for a = LO, HI do
    if touched[a] then
      if start then runs[#runs+1] = {start, a - start}; start = nil end
    else
      if not start then start = a end
    end
  end
  if start then runs[#runs+1] = {start, HI + 1 - start} end
  table.sort(runs, function(x, y) return x[2] > y[2] end)

  local total, poc, eng = 0, 0, 0
  for _, r in ipairs(runs) do
    total = total + r[2]
    if r[2] >= NEED_POC then poc = poc + 1 end
    if r[2] >= NEED_ENGINE then eng = eng + 1 end
  end
  for i = 1, math.min(#runs, 24) do
    local s, n = runs[i][1], runs[i][2]
    local tag = ""
    if n >= NEED_ENGINE then tag = "엔진 전체가 들어간다"
    elseif n >= NEED_POC then tag = "POC 훅이 들어간다" end
    row("run", string.format("$%04X", s), n,
        string.format("$%04X-$%04X  %d B  %s", s, s + n - 1, n, tag))
  end
  row("sum", total, #runs,
      string.format("안 쓰인 총 %d B / %d 조각 · 64B+ 조각 %d 개 · 1140B+ 조각 %d 개",
        total, #runs, poc, eng))
  file:write(string.format("-- 프레임 %d · 쓰기 %d 회 · 총 %d 행\n", frame, writes, rows))
  file:close()
end, emu.eventType.scriptEnded)

emu.log("PROBE 죽은 RAM 0.1.0 -- $2200-$3FFF 에서 오프닝이 안 건드리는 구간")
emu.log("  IRQ 훅은 항상 매핑된 창에만 둘 수 있다.  케이브($BCD2, MPR5)는 못 쓴다")
emu.log("  run 행: 64 B 이상이면 POC, 1,140 B 이상이면 엔진 전체")
emu.log("  오프닝을 끝까지 두고 Stop")
emu.log("  출력: " .. OUT)
