-- UI 0.1.72 : CD 적재 병목 계측 (0.1.71 의 두 버그 수정)
--
-- 0.1.71 이 왜 틀렸나
--   1) 제로페이지 주소를 틀렸다.
--      HuC6280 의 제로페이지는 CPU $0000 이 아니라 **$2000-$20FF** 다.
--      BIOS 변수 "$F8" 은 ZP 오프셋이고 실제 CPU 주소는 $20F8 이다.
--      ($F8,X 같은 opcode 의 $F8 은 ZP 오프셋. 절대주소가 아니다)
--      -> 0x00F8 을 읽어서 전부 FF 가 나왔다. 섹터수 255, LBA FFFFFF, 목적지 FFFF
--         전부 "매핑 안 된 자리" 였다.
--
--   2) '소요초' 를 첫 호출~마지막 호출 간격으로 냈다.
--      호출이 1회인 버스트는 무조건 1프레임이 되어 아무 정보가 없다.
--      우리가 알고 싶은 것은 **게임이 멈춰 있던 시간** 이다.
--
-- 이번에 재는 것
--   A. BIOS 파라미터 (주소 수정)
--        $20F8 $20F9 $20FA = _al _ah _bl = 시작 LBA
--        $20FB             = _bh         = 목적지 종류
--        $20FC $20FD       = _cl _ch     = 목적지 주소
--        $20FF             = _dh         = 읽을 섹터 수
--      확인용으로 $00F8 쪽도 같이 읽어 보고에 찍는다. 어느 쪽이 진짜인지 데이터로 판단.
--
--   B. 체감 정지 시간 — 프레임마다 PC 를 보고 BIOS 안($E000+)이면 센다
--        BIOS 체류 프레임 / 60 = 게임이 CD 에 붙잡혀 있던 초
--      이것이 "11.83초" 와 대조할 진짜 숫자다.
--
--   C. 호출 간격 (ms) — 연속 호출 사이 프레임 수로 낸다
--
-- 사용법
--   ac_0.1.11 로 실행. 파워 사이클.
--   11.83초 걸리는 그 장면까지 진행. 적재 끝나면 자동 보고.
--
-- 판정
--   호출당 섹터 1        개별 읽기. 멀티섹터로 뭉치면 그만큼 빨라진다
--   호출당 섹터 크고
--   BIOS 체류도 길다     CD 전송 자체가 오래 걸린다 = 바이트를 줄여야 한다
--   호출당 섹터 크고
--   BIOS 체류가 짧다     CD 는 무죄. 포트 쓰기/조립 코드가 병목 -> WATCH_PORTS

local WATCH_PORTS = false   -- 2차 측정에서만 true (콜백 수십만 번 = 타이밍 왜곡)

local mem = emu.memType.pceMemory

local BIOS_CD_READ = 0xE009
local ZP = 0x2000           -- HuC6280 제로페이지 베이스
local BURST_GAP = 60

local FPS = 60.0
local CD_RATE = 150 * 1024

local frames = 0
local biosFrames = 0        -- PC 가 BIOS 안이었던 프레임
local calls = {}
local bursts = {}
local cur = nil
local lastCallFrame = -9999
local reportedBursts = 0
local portW, portR = 0, 0
local zpNoteDone = false

local function rd(a) return emu.read(a, mem) or 0 end

local function onCdRead()
  -- 수정된 주소 ($20F8-$20FF)
  local lba = rd(ZP + 0xF8) + rd(ZP + 0xF9) * 0x100 + rd(ZP + 0xFA) * 0x10000
  local destType = rd(ZP + 0xFB)
  local destAddr = rd(ZP + 0xFC) + rd(ZP + 0xFD) * 0x100
  local count = rd(ZP + 0xFF)

  -- 대조용 (0.1.71 이 읽던 자리)
  local badCount = rd(0xFF)
  local badLba = rd(0xF8) + rd(0xF9) * 0x100 + rd(0xFA) * 0x10000

  local gap = (#calls > 0) and (frames - calls[#calls].f) or 0

  calls[#calls + 1] = {
    f = frames, lba = lba, count = count,
    destType = destType, destAddr = destAddr, gap = gap,
    badCount = badCount, badLba = badLba,
    biosF = biosFrames,
  }

  if cur == nil or (frames - lastCallFrame) > BURST_GAP then
    cur = {
      startF = frames, endF = frames, n = 0, sectors = 0,
      lbaMin = lba, lbaMax = lba, cMin = count, cMax = count,
      dest = {}, gapMax = 0, gapSum = 0,
      biosStart = biosFrames, pwStart = portW,
    }
    bursts[#bursts + 1] = cur
  end
  cur.endF = frames
  cur.n = cur.n + 1
  cur.sectors = cur.sectors + count
  if lba < cur.lbaMin then cur.lbaMin = lba end
  if lba > cur.lbaMax then cur.lbaMax = lba end
  if count < cur.cMin then cur.cMin = count end
  if count > cur.cMax then cur.cMax = count end
  if cur.n > 1 then
    cur.gapSum = cur.gapSum + gap
    if gap > cur.gapMax then cur.gapMax = gap end
  end
  local key = string.format("%02X:%04X", destType, destAddr)
  cur.dest[key] = (cur.dest[key] or 0) + 1
  cur.biosEnd = biosFrames
  cur.pwEnd = portW

  lastCallFrame = frames
end

local function onPortW() portW = portW + 1 end
local function onPortR() portR = portR + 1 end

local function reportBurst(b, idx)
  local L = {}
  local function W(s) L[#L + 1] = s end

  local spanF = b.endF - b.startF + 1
  local spanS = spanF / FPS
  local biosF = (b.biosEnd or 0) - (b.biosStart or 0)
  local biosS = biosF / FPS
  local bytes = b.sectors * 2048
  local xfer = bytes / CD_RATE
  local avgSec = b.n > 0 and (b.sectors / b.n) or 0
  local avgGap = b.n > 1 and (b.gapSum / (b.n - 1)) or 0

  W("")
  W(string.format("=== 적재 버스트 #%d ===", idx))
  W(string.format("  프레임 %d ~ %d   호출 spread %.2f초", b.startF, b.endF, spanS))
  W("")
  W(string.format("  CD_READ 호출     %d회", b.n))
  W(string.format("  총 섹터          %d섹터  (%d B = %.0f KB)",
    b.sectors, bytes, bytes / 1024))
  W(string.format("  호출당 섹터      평균 %.2f   (최소 %d / 최대 %d)",
    avgSec, b.cMin, b.cMax))
  W(string.format("  LBA 범위         %d ~ %d", b.lbaMin, b.lbaMax))
  local dl = {}
  for k, n in pairs(b.dest) do dl[#dl + 1] = string.format("%s x%d", k, n) end
  W("  목적지(bh:addr)  " .. table.concat(dl, "  "))
  if b.n > 1 then
    W(string.format("  호출 간격        평균 %.1f프레임 (%.0f ms) / 최대 %d프레임 (%.0f ms)",
      avgGap, avgGap / FPS * 1000, b.gapMax, b.gapMax / FPS * 1000))
  end
  W("")
  W("  --- 체감 정지 시간 (핵심) ---")
  W(string.format("  BIOS 체류        %d프레임 = %.2f초", biosF, biosS))
  W(string.format("  버스트 전체      %.2f초 중 %.0f%% 를 CD BIOS 에서 보냈다",
    spanS, spanS > 0 and 100 * biosS / spanS or 0))
  W(string.format("  이론 전송        %.2f초  (%.0f KB / 150KB/s)", xfer, bytes / 1024))
  W("")
  W("  --- 판정 ---")
  if avgSec <= 1.05 then
    W("  🔴 호출당 1섹터. 개별 읽기.")
    W(string.format("     %d회를 멀티섹터 1회로 뭉치면 대부분 사라진다", b.n))
  elseif biosS > 1.0 and xfer > 0.5 then
    W(string.format("  🔴 호출당 %.0f섹터로 이미 뭉쳐 읽지만 BIOS 체류가 %.2f초다.", avgSec, biosS))
    W(string.format("     %.0f KB 를 읽고 있다. **바이트를 줄여야 한다.**", bytes / 1024))
    W("     레코드 704B->96B (글리프를 AC 전역 아틀라스로) = 7배 감소")
  elseif biosS > 1.0 then
    W(string.format("  🟡 BIOS 체류 %.2f초. 전송량(%.0f KB)에 비해 오래 걸린다.", biosS, bytes / 1024))
    W("     시크가 잦거나 목적지 쓰기가 느린 경우다. LBA 범위를 확인할 것.")
  else
    W(string.format("  🟢 BIOS 체류 %.2f초뿐. CD 는 병목이 아니다.", biosS))
    W("     남은 시간은 포트 쓰기나 레코드 조립 코드에서 쓰고 있다.")
    W("     -> WATCH_PORTS = true 로 2차 측정")
  end

  if not zpNoteDone and #calls > 0 then
    local c = calls[#calls]
    W("")
    W("  [주소 검증]")
    W(string.format("    $20FF (수정) 섹터수 %d   $00FF (0.1.71) %d",
      c.count, c.badCount))
    W(string.format("    $20F8 (수정) LBA %d   $00F8 (0.1.71) %d",
      c.lba, c.badLba))
    if c.badCount == 0xFF and c.count ~= 0xFF then
      W("    -> 수정된 주소가 맞다. 0.1.71 은 매핑 안 된 자리를 읽었다.")
    elseif c.count == 0xFF and c.badCount ~= 0xFF then
      W("    -> 뒤바뀌었다. $00xx 가 맞는 환경이다.")
    end
    zpNoteDone = true
  end

  emu.log("")
  emu.log("### 아래를 그대로 복사하세요 ###")
  for _, x in ipairs(L) do emu.log(x) end
  emu.log("### 여기까지 ###")
end

local function summary()
  local L = {}
  local function W(s) L[#L + 1] = s end
  W("")
  W("=== 전체 요약 ===")
  W(string.format("경과 %d프레임 (%.1f분)   버스트 %d개   총 호출 %d회",
    frames, frames / 3600.0, #bursts, #calls))
  W(string.format("BIOS 체류 누적   %d프레임 = %.2f초  (전체의 %.1f%%)",
    biosFrames, biosFrames / FPS, frames > 0 and 100 * biosFrames / frames or 0))
  if WATCH_PORTS then
    W(string.format("$1A00 포트  쓰기 %d회 / 읽기 %d회", portW, portR))
  end
  W("")
  W(string.format("%-6s %6s %8s %9s %9s %9s",
    "버스트", "호출", "섹터", "섹터/호출", "KB", "BIOS초"))
  W(string.rep("-", 54))
  for i, b in ipairs(bursts) do
    local biosS = ((b.biosEnd or 0) - (b.biosStart or 0)) / FPS
    W(string.format("%-6d %6d %8d %9.1f %9.0f %9.2f",
      i, b.n, b.sectors, b.n > 0 and b.sectors / b.n or 0,
      b.sectors * 2048 / 1024, biosS))
  end
  emu.log("")
  emu.log("### 아래를 그대로 복사하세요 ###")
  for _, x in ipairs(L) do emu.log(x) end
  emu.log("### 여기까지 ###")
end

local function onFrame()
  frames = frames + 1

  -- 체감 정지: PC 가 BIOS 안이면 게임이 CD 에 붙잡혀 있는 것
  local ok, st = pcall(emu.getState)
  if ok and st ~= nil then
    local pc = st["cpu.pc"]
    if pc ~= nil and pc >= 0xE000 then
      biosFrames = biosFrames + 1
    end
  end

  if cur ~= nil and (frames - lastCallFrame) == BURST_GAP then
    reportedBursts = reportedBursts + 1
    reportBurst(cur, reportedBursts)
    cur = nil
  end

  if frames % 1800 == 0 and #bursts > 0 then summary() end
end

emu.addMemoryCallback(onCdRead, emu.callbackType.exec,
  BIOS_CD_READ, BIOS_CD_READ, emu.cpuType.pce, mem)

if WATCH_PORTS then
  emu.addMemoryCallback(onPortW, emu.callbackType.write,
    0x1A00, 0x1AFF, emu.cpuType.pce, mem)
  emu.addMemoryCallback(onPortR, emu.callbackType.read,
    0x1A00, 0x1AFF, emu.cpuType.pce, mem)
end

emu.addEventCallback(onFrame, emu.eventType.endFrame)

emu.log("UI 0.1.72 loaded - CD 적재 병목 계측 (0.1.71 버그 수정)")
emu.log("  수정1: 제로페이지를 $20F8-$20FF 로 (HuC6280 ZP 는 $2000 베이스)")
emu.log("  수정2: '체감 정지' 를 BIOS 체류 프레임으로 직접 셈")
emu.log("  11.83초 걸리는 그 장면까지 진행하세요")
