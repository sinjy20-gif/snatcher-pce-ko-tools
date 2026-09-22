-- PROBE_SOFTLOAD_PTR 0.1.1 - 소프트 복귀에서 갱신되지 않는 값을 찾는다
--
-- 무엇을 묻는가
-- -------------
-- §8-B 는 "재로드 경로가 우리 코드를 그래픽 소스로 읽는다"로 설명됐다. 그런데 그
-- 설명만으로는 비대칭이 풀리지 않는다.
--
--   파워사이클 → 로드        정상
--   저장 → 타이틀 → 재로드    깨짐
--
-- 재로드 경로가 같다면 둘 다 읽어야 한다. 한쪽만 깨진다는 것은 읽는 행위 자체가
-- 소프트 복귀에서만 일어나거나, 읽는 대상 주소가 다르다는 뜻이다. 어느 쪽이든
-- 결론은 하나다 -- 소프트 복귀에서 초기화되지 않는 값이 있다.
--
-- 후보는 이미 특정돼 있다. 문제의 전송 루프가 이것이다.
--
--   B1 12    LDA ($12),Y      <- 제로페이지 $12/$13 이 소스 주소를 가리킨다
--   JSR $71B0
--   INY / CPY $01 / BNE
--
-- 즉 전송원이 제로페이지 포인터 하나로 정해진다. 부팅 때는 세팅되는데 소프트
-- 복귀에서 갱신이 빠지면, 낡은 값이 남아 원래 FF 였고 지금은 우리 코드가 있는
-- 자리를 소스로 읽는다.
--
-- 중요 -- 제로페이지의 실제 위치
-- ------------------------------
-- HuC6280 의 제로페이지는 MPR1 이 RAM 을 매핑한 곳이다. 이 게임은 MPR1=$F8 이라
-- RAM 이 CPU $2000 부터 있고, 따라서 $12/$13 은 **$2012/$2013** 이다. CPU $0012 는
-- MPR0=$FF (I/O 페이지)라 읽으면 항상 $FF 가 나온다.
-- (통합 인계서에서 $F8 대신 $20F8 이어야 했던 것과 같은 함정이다.)
--
-- 어떻게 쓰는가
-- -------------
--   1) 패치 디스크(0.3.3)를 열고 이 스크립트를 Run
--   2) 경로 A -- 파워사이클 → 게임 내 로드 → 대사가 몇 줄 나올 때까지
--   3) Script Window 를 그대로 두고, 경로 B -- 게임 안에서 저장 → 타이틀 →
--      같은 슬롯 재로드 → 대사가 나올 때까지
--   4) 출력 TSV 를 넘긴다
--
-- 경로를 나누기 위해 F5 를 누르면 mark 행이 찍힌다. A 를 마치고 한 번, B 를
-- 마치고 한 번 눌러 두면 판독이 쉽다.
--
-- 무엇을 보는가
-- -------------
--   ptr        전송 직전 $2012/$2013 값
--   src        그 포인터가 가리키는 실제 주소
--   in_patch   그 주소가 우리 패치 구간 안인가
--
-- 판정
-- ----
--   A 와 B 의 ptr 이 다르다   -> 원인 확정. 초기화 누락 한 곳. 국소적이다
--   같다                      -> 포인터는 무죄. 순정 디스크 비교로 넘어간다

-- 잘 도는 runtime_text_audit.lua 와 같은 타입을 쓴다.  emu.memType.cpu 로 읽으면
-- 0 만 나온다(0.1.0 의 실패 원인).
local cpu = emu.memType.pceMemory
local OUT = string.format("C:\\snatcher\\dump\\softload_ptr_%s.tsv", os.date("%H%M%S"))

-- 제로페이지는 RAM 이 매핑된 $2000 부터다.  $0012 가 아니다.
local ZP = 0x2000
local PTR_LO, PTR_HI = ZP + 0x12, ZP + 0x13

-- 전송 루프의 읽기 명령.  여기 도달했을 때의 포인터가 곧 전송원이다.
local COPY_LDA = 0x70BF

-- 우리가 코드를 넣은 구간.  원본에서는 전부 FF 였다.
local PATCH_RANGES = {
  { name = "record_tail_helper", lo = 0x5E20, hi = 0x5E3F },
  { name = "preloader",          lo = 0x5E40, hi = 0x5FF1 },
  { name = "font_wrapper",       lo = 0x7F50, hi = 0x7FFD },
  { name = "helper_cave",        lo = 0xBCD2, hi = 0xBFFF },
}

local frames, hits, marks = 0, 0, 0
local lastKey = nil

local file = io.open(OUT, "w")
if file == nil then
  emu.log("PTR PROBE: cannot open " .. OUT)
  return
end
file:write("kind\tframe\tptr\tsrc\tin_patch\tmpr1\tmpr5\tcount\tzp10\n")
file:flush()

local function state()
  local ok, s = pcall(emu.getState)
  if ok and s then return s end
  return {}
end

local function mprOf(s, slot)
  local v = s[string.format("memoryManager.mpr[%d]", slot)]
  if v == nil and type(s.memoryManager) == "table" and type(s.memoryManager.mpr) == "table" then
    v = s.memoryManager.mpr[slot]
  end
  return v or -1
end

local function byte(a) return emu.read(a, cpu) or 0 end

local function whichPatch(addr)
  for _, r in ipairs(PATCH_RANGES) do
    if addr >= r.lo and addr <= r.hi then return r.name end
  end
  return ""
end

-- $12/$13 만 보면 0 이 나왔을 때 "포인터가 정말 0"인지 "잘못 읽었는지" 구분할 수
-- 없다.  0.1.0 이 그 구분을 못 해 한 번 헛돌았으므로 주변 16바이트를 같이 남긴다.
local function zpWindow()
  local out = {}
  for i = 0x10, 0x1F do out[#out + 1] = string.format("%02X", byte(ZP + i)) end
  return table.concat(out, " ")
end

local function write(kind, ptr, src, tag, s, count)
  file:write(string.format("%s\t%d\t$%04X\t$%04X\t%s\t%02X\t%02X\t%d\t%s\n",
    kind, frames, ptr, src, tag, mprOf(s, 1), mprOf(s, 5), count or 0, zpWindow()))
  file:flush()
end

-- 전송 직전 포인터를 읽는다.  같은 값이 연속으로 나오면 한 줄만 남긴다:
-- 이 루프는 한 번의 전송에서 수백 번 돈다.
emu.addMemoryCallback(function()
  hits = hits + 1
  local lo, hi = byte(PTR_LO), byte(PTR_HI)
  local ptr = lo + hi * 256
  local key = string.format("%04X", ptr)
  if key == lastKey then return end
  lastKey = key
  local s = state()
  local tag = whichPatch(ptr)
  write("ptr", ptr, ptr, tag ~= "" and tag or "-", s, hits)
  emu.log(string.format("PTR $%04X %s (f%d)", ptr, tag ~= "" and ("<- " .. tag) or "", frames))
end, emu.callbackType.exec, COPY_LDA, COPY_LDA, emu.cpuType.pce, cpu)

-- F5 = 구간 표시.  경로 A 를 마치고 한 번, B 를 마치고 한 번.
emu.addEventCallback(function()
  frames = frames + 1
  if emu.isKeyPressed("F5") then
    if marks == 0 or frames - marks > 30 then
      marks = frames
      local s = state()
      write("mark", 0, 0, "MARK", s, hits)
      emu.log(string.format("---- MARK (f%d, 지금까지 전송 %d회) ----", frames, hits))
    end
  end
end, emu.eventType.endFrame)

emu.log("PROBE_SOFTLOAD_PTR 0.1.1 loaded")
emu.log("  전송원 포인터 $2012/$2013 을 $70BF 진입 시점에 기록한다")
emu.log("  경로 A(파워사이클→로드) 마친 뒤 F5, 경로 B(저장→타이틀→재로드) 마친 뒤 F5")
emu.log("  출력: " .. OUT)
