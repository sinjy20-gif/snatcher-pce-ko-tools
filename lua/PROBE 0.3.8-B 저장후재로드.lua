-- PROBE 0.3.8-B - 실험군: 저장 후 재로드 (§8-B)
--
-- 왜 파일을 둘로 나눴나
-- --------------------
-- 0.3.7 은 한 스크립트에서 Q 키로 A/B 구간을 갈랐다.  그래서 "이 HIT 이 A 냐 B 냐"가
-- **사람이 Q 를 언제 눌렀는지**에 달려 버렸고, 08-15 에 실제로 두 번 헷갈렸다.
-- 대조군은 조건만 달라야 하는데 스크립트 안에 사람이 누르는 스위치를 넣은 것이
-- 설계 실수였다.
--
-- 이 파일에는 스위치가 없다.  **기록되는 것은 전부 재로드 경로다.**
-- 짝은 `PROBE 0.3.8-A 정상로드.lua` 이고, 둘은 파일 이름과 출력 경로만 다르다.
-- 기록 로직은 A 와 한 글자도 다르지 않다 -- 그래야 차이가 조건에서만 온다.
--
-- 무엇을 재는가
-- -------------
-- 깨진 화면을 만드는 전송 루프가 이것이다.
--
--   B1 12    LDA ($12),Y      <- 제로페이지 $12/$13 이 전송원을 가리킨다
--   JSR $71B0                 <- VDC 전송
--   INY / CPY $01 / BNE
--
-- 그 루프가 돌 때마다 셋을 한 줄에 담는다.
--
--   전송원   $2012/$2013           포인터를 쓰는 쪽이 아니라 **쓰이는 순간**을 본다
--   목적지   vdc.memAddrWrite      VDC MAWR
--   길이     $2001                 루프가 CPY $01 로 비교하는 값
--
-- 제로페이지의 실제 위치 -- 틀리기 쉬운 곳
--   MPR1=$F8 이라 RAM 이 CPU $2000 부터다.  따라서 $12/$13 은 $2012/$2013.
--   CPU $0012 는 MPR0=$FF(I/O 페이지)라 읽으면 항상 $FF 가 나온다.
--
-- 쓰는 법
-- -------
--   1) 디스크를 올리고 Run  (이미 플레이 중인 상태여도 된다)
--   2) 게임 안에서 저장 -> 타이틀 -> 같은 슬롯 재로드
--   3) 대사 몇 줄  (화면이 깨진 것을 확인)
--   4) **Stop**
--
-- **Stop 을 반드시 할 것.**  census 는 Stop 에서만 기록된다.  08-15 에 네 번
-- 놓쳐 전송 총계를 못 받았다.  F5 는 쓰지 않는다 (Mesen 세이브 스테이트와 겹친다).
--
-- 판정은 B 와 대조해서 한다
--   A 0건 · B 여러 건    B 에서만 빗나간다 -> 원인 확정
--   둘 다 비슷           정상 경로도 그 자리를 읽는다 -> 다른 설명이 필요하다

local mem = emu.memType.pceMemory      -- emu.read 용.  memType.cpu 는 0 만 나온다
local cpu = emu.memType.cpu            -- 콜백 등록용

local PHASE = "B"

local ZP       = 0x2000
local PTR_LO   = ZP + 0x12
local PTR_HI   = ZP + 0x13
local LEN_ADDR = ZP + 0x01
local COPY_LDA = 0x70BF

local CAVE = {
  ["0.3.5"] = { lo = 0xBCD2, hi = 0xBFFF },
  ["0.3.4"] = { lo = 0xBCD2, hi = 0xBFFF },
  ["0.3.3"] = { lo = 0xBCD2, hi = 0xBFFF },
}

local function detectBuild()
  local ok, info = pcall(emu.getRomInfo)
  local name = ok and info and (info.name or info.path) or ""
  return name:match("%[KO ([^%]]+)%]"), name
end
local BUILD, ROM = detectBuild()
local cave = CAVE[BUILD] or CAVE["0.3.5"]
if BUILD == nil then BUILD = "unknown" end

-- 우리가 코드를 넣은 구간.  원본에서는 전부 FF 였다.
local PATCH = {
  { name = "record_tail_helper", lo = 0x5E20, hi = 0x5E3F },
  { name = "preloader",          lo = 0x5E40, hi = 0x5FF1 },
  { name = "fractional",         lo = 0x64B3, hi = 0x64E3 },
  { name = "renderer_hook",      lo = 0x66E5, hi = 0x66E7 },
  { name = "space_hook",         lo = 0x674A, hi = 0x674C },
  { name = "font_wrapper",       lo = 0x7F50, hi = 0x7FFD },
  { name = "helper_cave",        lo = cave.lo, hi = cave.hi },
}
-- 캐시는 글리프 데이터라 $70BF 가 읽는 것이 정상이다.  세면 폰트 전송에 묻힌다.
local CACHE_LO, CACHE_HI = 0x5B80, 0x5E1F

-- VRAM 목적지 분류.  경계는 08-15 VRAM 덤프 실측이다.
-- MAWR 은 16비트라 VRAM 워드 범위($0000-$7FFF)를 넘는 값이 나올 수 있어 감아서 본다.
local function vramRegion(addr)
  if addr == nil then return "?" end
  local a = addr % 0x8000
  if a < 0x1000 then return "BAT" end
  if a < 0x34C0 then return "패턴" end
  if a <= 0x3FFF then return "폰트타일" end
  if a >= 0x7F00 then return "SATB" end
  return "기타"
end

local OUT = string.format("C:\\snatcher\\dump\\probe_v038b_%s_%s.tsv",
                          BUILD, os.date("%H%M%S"))
local file = assert(io.open(OUT, "w"))
file:write("kind\tphase\tframe\tsrc\tsrc_range\tdst\tdst_raw\tdst_region\tlen\tcount\tnote\n")
file:flush()

local frame, closed = 0, false
local seen, hits, reads, moves = {}, 0, 0, 0
local dstHist = {}
local lastPtr = nil

local function row(kind, src, srcRange, dst, dstRegion, len, count, note)
  if closed then return end
  file:write(string.format("%s\t%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\n",
    kind, PHASE, frame,
    src and string.format("$%04X", src) or "-",
    srcRange or "-",
    dst and string.format("$%04X", dst % 0x8000) or "-",
    dst and string.format("$%04X", dst) or "-",
    dstRegion or "-",
    len and tostring(len) or "-",
    count or 0, note or ""))
  file:flush()
end

local function whichPatch(addr)
  for _, r in ipairs(PATCH) do
    if addr >= r.lo and addr <= r.hi then return r.name end
  end
  return nil
end

local function destination()
  local ok, state = pcall(emu.getState)
  if not ok or state == nil then return nil end
  return state["vdc.memAddrWrite"]
end

-- 루프는 바이트마다 돈다(정상 플레이 5,409 프레임에 40,237 회).  매번 getState 를
-- 부르면 에뮬이 기어가므로, **포인터가 바뀔 때만** 무거운 읽기를 한다.
emu.addMemoryCallback(function()
  reads = reads + 1
  local lo = emu.read(PTR_LO, mem) or 0
  local hi = emu.read(PTR_HI, mem) or 0
  local ptr = lo + hi * 256
  if ptr == lastPtr then return end
  lastPtr = ptr
  moves = moves + 1

  seen[ptr] = (seen[ptr] or 0) + 1
  if ptr >= CACHE_LO and ptr <= CACHE_HI then return end
  local name = whichPatch(ptr)
  if name == nil then return end

  hits = hits + 1
  local dst = destination()
  local region = vramRegion(dst)
  local len = emu.read(LEN_ADDR, mem)
  dstHist[region] = (dstHist[region] or 0) + 1

  if seen[ptr] <= 3 then
    row("HIT", ptr, name, dst, region, len, seen[ptr], "패치 구간을 전송원으로 읽음")
    emu.log(string.format("[B] HIT src=$%04X(%s) -> dst=$%04X(%s) len=%s f%d",
      ptr, name, (dst or 0) % 0x8000, region, tostring(len), frame))
  end
end, emu.callbackType.exec, COPY_LDA, COPY_LDA, emu.cpuType.pce, cpu)

emu.addEventCallback(function() frame = frame + 1 end, emu.eventType.endFrame)

emu.addEventCallback(function()
  local list = {}
  for ptr, n in pairs(seen) do list[#list + 1] = { ptr, n } end
  table.sort(list, function(a, b) return a[2] > b[2] end)

  row("census", nil, nil, nil, nil, nil, reads,
      string.format("바이트 %d · 전송 %d · 고유 포인터 %d · 패치구간 %d",
                    reads, moves, #list, hits))

  local parts = {}
  for region, n in pairs(dstHist) do
    parts[#parts + 1] = string.format("%s(%d)", region, n)
  end
  row("census", nil, nil, nil, nil, nil, hits,
      "패치구간 전송의 목적지: " ..
      (#parts > 0 and table.concat(parts, " · ") or "없음"))

  for i = 1, math.min(12, #list) do
    local ptr, n = list[i][1], list[i][2]
    row("top", ptr, whichPatch(ptr) or
        ((ptr >= CACHE_LO and ptr <= CACHE_HI) and "cache" or "-"),
        nil, nil, nil, n, "")
  end

  closed = true
  file:close()
  emu.log(string.format("PROBE 0.3.8-B [%s]: 전송 %d · 패치구간 %d -> %s",
    BUILD, moves, hits, OUT))
end, emu.eventType.scriptEnded)

emu.log(string.format("PROBE 0.3.8-B loaded  (빌드 %s)  -- 실험군: 저장 후 재로드", BUILD))
emu.log("  디스크: " .. tostring(ROM))
emu.log("  저장 -> 타이틀 -> 같은 슬롯 재로드 -> 대사 몇 줄 -> Stop")
emu.log("  ** Stop 을 해야 census 가 남는다 **")
emu.log("  출력: " .. OUT)
