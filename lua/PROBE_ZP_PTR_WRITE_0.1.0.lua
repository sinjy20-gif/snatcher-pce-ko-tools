-- PROBE_ZP_PTR_WRITE 0.1.0 - 전송원 포인터를 "쓰는 놈"을 잡는다
--
-- 왜 훅을 반대편으로 옮겼나
-- --------------------------
-- PROBE_SOFTLOAD_PTR 0.1.1 은 $70BF(읽는 쪽)에 exec 훅을 걸었다.  결과:
--
--   정상 플레이 5,409프레임   실행 40,237회   고유 포인터 1,900개
--   대역 8xxx 939 · 9xxx 540 · Axxx 272 · 5xxx 112 · Bxxx 22 · 6xxx 10 · Fxxx 5
--
-- $70BF 는 게임 전역의 범용 전송 루프였다.  읽는 쪽에 훅을 걸면 노이즈 40,237개에
-- 묻힌다.  (부수 성과 - 인계서 §4.3 "우리 구간만 읽나, 훑다 지나가나"에 답이
-- 나왔다: 훑는다.  따라서 "소스에서 우리 구간만 FF 로 보이게" 하는 마스킹 안은
-- 판별 근거가 없어 기각이다.)
--
-- 그런데 같은 $70BF 가 깨짐 발생 시에는 우리 구간에 집중한다.
--
--   3차 §5   f7582-7610  28프레임   $5E20-$5FF1 읽기 11,291회  VDC write 85,000
--   오늘     f195-5604  5,409프레임 같은 구간 포인터 1개
--
-- 즉 루프는 죄가 없고 **$12/$13 에 들어간 값**이 다르다.  그러면 물어야 할 것은
-- 하나뿐이다 -- 그 값을 쓴 놈의 PC 는 무엇인가.
--
-- 이 프로브는 $2012/$2013 에 write 훅을 걸고, 우리 패치 구간을 가리키는 값이
-- 쓰이는 순간의 PC 를 찍는다.  A/B 비교가 필요 없다.  경로 B 한 번이면 된다.
--
-- 제로페이지의 실제 위치
-- ----------------------
-- MPR1=$F8 이라 RAM 이 CPU $2000 부터다.  $12/$13 은 **$2012/$2013**.
-- CPU $0012 는 MPR0=$FF (I/O 페이지)다.
--
-- 영향 범위도 같이 잰다
-- ---------------------
-- "어느 정도 영향인가"는 오염된 VRAM 이 어디까지인지로 갈린다.  VDC 포트를 따라
-- MAWR(레지스터 $00)을 추적해 전송 목적지의 최소/최대 주소를 남긴다.
--
--   좁은 한 구역     배경 패턴 일부.  화면만 지저분하고 국소적
--   넓게 흩어짐      SATB·BAT 까지 번짐.  더 큰 오염의 첫 증상일 수 있음
--
-- 쓰는 법
-- -------
--   1) 패치 디스크(0.3.3) → 이 스크립트 Run
--   2) 플레이 → 게임 내 저장 → 타이틀 복귀 → 같은 슬롯 재로드
--   3) 화면이 깨지는 것을 눈으로 확인한 뒤 정지
--   4) dump\zpptr_write_*.tsv 를 넘긴다
--
-- 읽는 법
-- -------
--   kind=HIT     패치 구간을 가리키는 값이 쓰였다.  pc 가 범인 후보
--   kind=census  PC 별 누적 (정지 시 1회).  누가 이 포인터를 관리하는지
--   kind=vram    전송이 몰린 프레임의 VDC 목적지 범위
--
-- 판정
-- ----
--   HIT 의 pc 가 소수(1~2개)     초기화 누락 한 곳.  국소적임이 증명된다
--   HIT 가 0건인데 깨짐은 발생   포인터 경유가 아니다.  TIA/TII 블록전송 쪽
--   HIT 의 pc 가 수십 개         범용 경로.  국소 수정 불가 -> 보류 판단

local mem = emu.memType.pceMemory      -- emu.read 용.  emu.memType.cpu 는 0 만 나온다
local cpu = emu.memType.cpu            -- 콜백 등록용 (SAVE 0.1.3 과 동일)
local OUT = string.format("C:\\snatcher\\dump\\zpptr_write_%s.tsv", os.date("%H%M%S"))

local ZP = 0x2000
local PTR_LO, PTR_HI = ZP + 0x12, ZP + 0x13

-- 우리가 코드를 넣은 구간.  원본에서는 전부 FF 였다.
-- $5B80-$5E1F 캐시는 뺀다 -- 거기는 글리프 데이터라 $70BF 가 읽는 것이 정상이다.
-- 그것까지 HIT 로 잡으면 평상시 폰트 전송이 전부 걸려 로그가 무의미해진다.
local PATCH_RANGES = {
  { name = "record_tail_helper", lo = 0x5E20, hi = 0x5E3F },
  { name = "preloader",          lo = 0x5E40, hi = 0x5FF1 },
  { name = "font_hook",          lo = 0x648C, hi = 0x648E },
  { name = "fractional",         lo = 0x64B3, hi = 0x64E3 },
  { name = "renderer_hook",      lo = 0x66E5, hi = 0x66E7 },
  { name = "space_hook",         lo = 0x674A, hi = 0x674C },
  { name = "font_loader_state",  lo = 0x7F50, hi = 0x7FFF },
  { name = "helper_cave",        lo = 0xBCD2, hi = 0xBFFF },
}

-- 참고용.  HIT 로 세지는 않지만 census 에서 구분해 보여준다.
local CACHE_LO, CACHE_HI = 0x5B80, 0x5E1F

local file = assert(io.open(OUT, "w"))
file:write("kind\tframe\tpc\tptr\trange\tcount\tvdc\tvram_lo\tvram_hi\tnote\n")
file:flush()

local frame        = 0
local vdcWrites    = 0
local writerCensus = {}   -- pc -> { total, toPatch, toCache, sample }
local seenHit      = {}   -- pc:ptr -> count  (같은 조합 반복은 세기만)
local hitRows      = 0

-- VDC 목적지 추적 --------------------------------------------------------
-- 포트 $0000 = 레지스터 선택,  $0002/$0003 = 데이터.
-- 선택 레지스터가 $00(MAWR)이면 뒤따르는 데이터가 VRAM 쓰기 주소다.
-- 선택 레지스터가 $02(VWR)면 $0003 쓰기마다 한 워드가 커밋되고 주소가 오른다.
local vdcReg   = 0
local mawrLo   = 0
local vramAddr = 0
local vramLo, vramHi = nil, nil   -- 이번 프레임에 건드린 VRAM 범위

local function noteVram(addr)
  if vramLo == nil or addr < vramLo then vramLo = addr end
  if vramHi == nil or addr > vramHi then vramHi = addr end
end

local function whichPatch(addr)
  for _, r in ipairs(PATCH_RANGES) do
    if addr >= r.lo and addr <= r.hi then return r.name end
  end
  return nil
end

local function pcNow()
  local ok, s = pcall(emu.getState)
  if not ok or s == nil then return 0 end
  return s["cpu.pc"] or (s.cpu and s.cpu.pc) or 0
end

local closed = false

local function row(kind, pc, ptr, rangeName, count, note)
  if closed then return end
  file:write(string.format("%s\t%d\t$%04X\t$%04X\t%s\t%d\t%d\t%s\t%s\t%s\n",
    kind, frame, pc, ptr, rangeName or "-", count or 0, vdcWrites,
    vramLo and string.format("$%04X", vramLo) or "-",
    vramHi and string.format("$%04X", vramHi) or "-",
    note or ""))
  file:flush()
end

-- $12/$13 쓰기 -----------------------------------------------------------
-- 콜백은 쓰기가 반영되기 전에 불리므로, 쓰이는 바이트는 인자 value 를 쓰고
-- 나머지 한 바이트만 메모리에서 읽는다.  둘 다 읽으면 반쪽 값이 나온다.
emu.addMemoryCallback(function(address, value)
  local lo, hi
  if address == PTR_LO then
    lo, hi = value, emu.read(PTR_HI, mem) or 0
  else
    lo, hi = emu.read(PTR_LO, mem) or 0, value
  end
  local ptr = lo + hi * 256

  local pc = pcNow()
  local c  = writerCensus[pc]
  if c == nil then
    c = { total = 0, toPatch = 0, toCache = 0, sample = ptr }
    writerCensus[pc] = c
  end
  c.total = c.total + 1

  if ptr >= CACHE_LO and ptr <= CACHE_HI then
    c.toCache = c.toCache + 1
    return
  end

  local hitRange = whichPatch(ptr)
  if hitRange == nil then return end

  c.toPatch = c.toPatch + 1

  -- 같은 (pc, ptr) 반복은 세기만 한다.  전송 준비는 한 프레임에 수백 번 돈다.
  local key = string.format("%04X:%04X", pc, ptr)
  local n = (seenHit[key] or 0) + 1
  seenHit[key] = n
  if n > 1 then return end

  hitRows = hitRows + 1
  row("HIT", pc, ptr, hitRange, n, "패치 구간을 가리키는 값이 쓰임")
  emu.log(string.format("HIT  pc=$%04X -> ptr=$%04X (%s)  f%d", pc, ptr, hitRange, frame))
end, emu.callbackType.write, PTR_LO, PTR_HI, emu.cpuType.pce, cpu)

-- VDC 포트 쓰기 ----------------------------------------------------------
emu.addMemoryCallback(function(address, value)
  vdcWrites = vdcWrites + 1
  if address == 0x0000 then
    vdcReg = value % 32
  elseif vdcReg == 0x00 then
    if address == 0x0002 then
      mawrLo = value
    elseif address == 0x0003 then
      vramAddr = mawrLo + value * 256
      noteVram(vramAddr)
    end
  elseif vdcReg == 0x02 and address == 0x0003 then
    noteVram(vramAddr)
    vramAddr = (vramAddr + 1) % 65536
  end
end, emu.callbackType.write, 0x0000, 0x0003, emu.cpuType.pce, cpu)

-- 프레임 경계 ------------------------------------------------------------
-- 전송이 몰린 프레임만 남긴다.  평상시 폰트 전송으로 로그가 넘치지 않도록
-- 문턱을 둔다 (3차 §5 의 깨짐 프레임은 프레임당 수천 회였다).
local VDC_BURST = 2000

emu.addEventCallback(function()
  frame = frame + 1
  if vdcWrites >= VDC_BURST then
    row("vram", 0, 0, "-", 0, string.format("VDC 폭주 프레임 (%d회)", vdcWrites))
  end
  vdcWrites = 0
  vramLo, vramHi = nil, nil
end, emu.eventType.endFrame)

-- 정지 시 census ---------------------------------------------------------
emu.addEventCallback(function()
  local pcs = {}
  for pc in pairs(writerCensus) do pcs[#pcs + 1] = pc end
  table.sort(pcs, function(a, b) return writerCensus[a].total > writerCensus[b].total end)
  for _, pc in ipairs(pcs) do
    local c = writerCensus[pc]
    row("census", pc, c.sample, "-", c.total, string.format(
      "패치행 %d · 캐시행 %d", c.toPatch, c.toCache))
  end
  row("census", 0, 0, "-", hitRows, string.format("고유 HIT 조합 %d개", hitRows))
  closed = true
  file:close()
  emu.log(string.format("PROBE_ZP_PTR_WRITE: 고유 HIT %d개, writer PC %d개 -> %s",
    hitRows, #pcs, OUT))
end, emu.eventType.scriptEnded)

emu.log("PROBE_ZP_PTR_WRITE 0.1.0 loaded")
emu.log("  $2012/$2013 에 패치 구간을 가리키는 값을 쓰는 PC 를 찍는다")
emu.log("  저장 -> 타이틀 -> 재로드 로 깨짐을 재현한 뒤 스크립트를 Stop 할 것")
emu.log("  Stop 해야 census 가 기록된다")
emu.log("  출력: " .. OUT)
