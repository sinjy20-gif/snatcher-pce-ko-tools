-- UI 0.1.73 : AC 적재 계측 (0.1.72 의 파라미터 해석 버그 수정)
--
-- 0.1.72 가 왜 틀렸나
--   제로페이지 주소($20F8)는 맞았지만 **파라미터 배치**를 틀렸다.
--   emit_cd_base 의 CD_BASE 규약과 load_blob 의 CD_READ 규약이 서로 다르다.
--
--   CD_READ 호출 시점의 실제 배치 (build_ac_dynamic_0_1_5.load_blob 기준)
--     $20F8  읽을 섹터 수          (8KiB 청크면 4)
--     $20F9  0
--     $20FA  목적지 뱅크           ($40 = Arcade Card 창 = 우리 전송)
--     $20FB  0
--     $20FC  0
--     $20FD  상대 섹터 상위        (CUR_HI. APPEND_RELATIVE_SECTOR = $C4B5)
--     $20FE  상대 섹터 하위        (CUR_LO)
--     $20FF  목적지 종류           (4 = MPR4)
--
--   0.1.72 는 $F8/$F9/$FA 를 LBA 로 읽어서 "4 + $40<<16 = 4,194,308" 을
--   LBA 라고 보고했고, $FF(목적지 종류 4)를 섹터 수라고 보고했다.
--   "호출당 섹터 4.00" 이 맞는 값이었던 것은 우연이다.
--
-- 이번 측정의 핵심
--   게임 자신의 CD 읽기와 우리 헬퍼의 읽기를 **뱅크로 분리**한다.
--     뱅크 $40  = 우리 (AC 로 전송)
--     그 외      = 게임 자신 (그래픽/음성 로딩)
--   0.1.72 데이터에서 21회가 우리 것이었고 11회가 게임 것이었다.
--
-- 사용법
--   ac_0.1.14 / 0.1.15 / 0.1.16 중 하나로 실행. 파워 사이클.
--   접수처 첫 대사까지 진행.  적재가 끝나면 자동 보고.
--   스톱워치와 같이 보면 호출당 실제 비용이 확정된다.
--
-- 판정
--   우리 호출 수가 곧 비용이다.  청크를 키우면 그만큼 줄어야 한다.
--     ac_0.1.14 ( 8KiB)  21회 예상
--     ac_0.1.15 (16KiB)  13회 예상
--     ac_0.1.16 (32KiB)   8회 예상
--   예상보다 많으면 BIOS 가 큰 청크를 쪼개고 있다는 뜻이다.

local mem = emu.memType.pceMemory
local BIOS_CD_READ = 0xE009
local ZP = 0x2000
local AC_BANK = 0x40          -- 우리 전송의 목적지 뱅크
local BURST_GAP = 60
local FPS = 60.0
local USER = 2048

local frames = 0
local ours, theirs = {}, {}
local bursts = {}
local cur = nil
local lastFrame = -9999
local reported = 0
local firstOurFrame, lastOurFrame = nil, nil

local function rd(a) return emu.read(a, mem) or 0 end

local function onCdRead()
  local sectors = rd(ZP + 0xF8)
  local bank = rd(ZP + 0xFA)
  local rel = rd(ZP + 0xFE) + rd(ZP + 0xFD) * 0x100
  local destType = rd(ZP + 0xFF)
  local mine = (bank == AC_BANK)

  local rec = { f = frames, sectors = sectors, bank = bank, rel = rel,
                destType = destType, mine = mine }
  if mine then
    ours[#ours + 1] = rec
    if firstOurFrame == nil then firstOurFrame = frames end
    lastOurFrame = frames
  else
    theirs[#theirs + 1] = rec
  end

  if cur == nil or (frames - lastFrame) > BURST_GAP then
    cur = { startF = frames, endF = frames, mine = 0, other = 0,
            mineSectors = 0, otherSectors = 0, relMin = nil, relMax = nil,
            banks = {}, gapSum = 0, gapN = 0, gapMax = 0 }
    bursts[#bursts + 1] = cur
  else
    local gap = frames - lastFrame
    cur.gapSum = cur.gapSum + gap
    cur.gapN = cur.gapN + 1
    if gap > cur.gapMax then cur.gapMax = gap end
  end
  cur.endF = frames
  cur.banks[bank] = (cur.banks[bank] or 0) + 1
  if mine then
    cur.mine = cur.mine + 1
    cur.mineSectors = cur.mineSectors + sectors
    if cur.relMin == nil or rel < cur.relMin then cur.relMin = rel end
    if cur.relMax == nil or rel > cur.relMax then cur.relMax = rel end
  else
    cur.other = cur.other + 1
    cur.otherSectors = cur.otherSectors + sectors
  end
  lastFrame = frames
end

local function emitLines(L)
  emu.log("")
  emu.log("### 아래를 그대로 복사하세요 ###")
  for _, x in ipairs(L) do emu.log(x) end
  emu.log("### 여기까지 ###")
end

local function reportBurst(b, idx)
  local L = {}
  local function W(s) L[#L + 1] = s end
  local span = (b.endF - b.startF + 1) / FPS
  W("")
  W(string.format("=== 버스트 #%d   프레임 %d~%d  (%.2f초) ===", idx, b.startF, b.endF, span))
  W(string.format("  우리($40)  %2d회  %4d섹터  %7d B",
    b.mine, b.mineSectors, b.mineSectors * USER))
  W(string.format("  게임        %2d회  %4d섹터  %7d B",
    b.other, b.otherSectors, b.otherSectors * USER))
  if b.mine > 0 then
    W(string.format("  상대섹터 %d ~ %d", b.relMin or 0, b.relMax or 0))
  end
  local bl = {}
  for bank, n in pairs(b.banks) do
    bl[#bl + 1] = string.format("$%02X x%d%s", bank, n, bank == AC_BANK and "(우리)" or "")
  end
  W("  뱅크  " .. table.concat(bl, "  "))
  if b.gapN > 0 then
    W(string.format("  호출 간격  평균 %.1f프레임 (%.0f ms) / 최대 %d프레임 (%.0f ms)",
      b.gapSum / b.gapN, b.gapSum / b.gapN / FPS * 1000,
      b.gapMax, b.gapMax / FPS * 1000))
  end
  emitLines(L)
end

local function summary()
  local L = {}
  local function W(s) L[#L + 1] = s end
  local sec = 0
  for _, r in ipairs(ours) do sec = sec + r.sectors end
  local osec = 0
  for _, r in ipairs(theirs) do osec = osec + r.sectors end

  W("")
  W("=== 전체 요약 ===")
  W(string.format("경과 %d프레임 (%.1f분)   버스트 %d개", frames, frames / 3600.0, #bursts))
  W("")
  W(string.format("우리($40 전송)  %3d회  %5d섹터  %8d B (%.0f KB)",
    #ours, sec, sec * USER, sec * USER / 1024))
  W(string.format("게임 자신       %3d회  %5d섹터  %8d B (%.0f KB)",
    #theirs, osec, osec * USER, osec * USER / 1024))
  if #ours > 0 then
    W(string.format("호출당 섹터     %.1f  (= 청크 %.0f KiB)",
      sec / #ours, sec / #ours * USER / 1024))
    W(string.format("우리 읽기 구간  프레임 %d ~ %d = %.2f초",
      firstOurFrame, lastOurFrame, (lastOurFrame - firstOurFrame + 1) / FPS))
  end
  W("")
  W("--- 기준 ---")
  W("  ac_0.1.14 ( 8KiB 청크)  21회 예상")
  W("  ac_0.1.15 (16KiB 청크)  13회 예상")
  W("  ac_0.1.16 (32KiB 청크)   8회 예상")
  if #ours > 0 then
    local per = sec / #ours
    if per >= 15.5 then
      W(string.format("  -> 호출당 %.0f섹터. 32KiB 청크가 그대로 전달되고 있다", per))
    elseif per >= 7.5 then
      W(string.format("  -> 호출당 %.0f섹터. 16KiB 청크가 그대로 전달되고 있다", per))
    else
      W(string.format("  -> 호출당 %.0f섹터. 8KiB 이다", per))
    end
  end
  W("")
  W("스톱워치로 잰 '첫 대사까지의 시간' 과 위 호출 수를 같이 적어주세요.")
  W("그 둘이면 호출당 실제 비용이 확정됩니다.")
  emitLines(L)
end

local function onFrame()
  frames = frames + 1
  if cur ~= nil and (frames - lastFrame) == BURST_GAP then
    reported = reported + 1
    reportBurst(cur, reported)
    cur = nil
  end
  if frames % 1800 == 0 and #bursts > 0 then summary() end
end

emu.addMemoryCallback(onCdRead, emu.callbackType.exec,
  BIOS_CD_READ, BIOS_CD_READ, emu.cpuType.pce, mem)
emu.addEventCallback(onFrame, emu.eventType.endFrame)

emu.log("UI 0.1.73 loaded - AC 적재 계측 (파라미터 해석 수정)")
emu.log("  $20F8=섹터수  $20FA=목적지뱅크  $20FD:$20FE=상대섹터  $20FF=목적지종류")
emu.log("  뱅크 $40 인 것만 우리 전송입니다. 게임 자신의 읽기와 분리해서 셉니다")
emu.log("  접수처 첫 대사까지 진행하고, 스톱워치 시간도 같이 적어주세요")
