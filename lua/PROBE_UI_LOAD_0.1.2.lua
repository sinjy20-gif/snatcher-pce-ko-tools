-- PROBE_UI_LOAD 0.1.2 - 선적재 빌드에서 재생 중 CD 접근이 진짜 0 인가
--
-- 0.1.1 이 밝힌 것
-- ----------------
-- 폐공장에서 **게임이 스스로 13~14 프레임 주기로 CD 를 읽는다.**  우리 코드가 전혀
-- 안 도는 프레임들이므로 게임 자신의 스트리밍이다.  거기에 우리 팩 수요적재가
-- 끼어들면 예외 없이 다음 읽기가 13 -> 22~30 프레임으로 밀렸다 (5건 중 5건).
--
-- 그래서 0.3.3-preload 를 만들었다.  팩 25개를 초기화 때 한 번에 올려 재생 중
-- CD 접근을 없앤 빌드다.  그런데 **깜빡임이 그대로였다.**
--
-- 그러면 갈림길은 둘뿐이고, 이 프로브가 그것을 가른다
-- ---------------------------------------------------
--   재생 중 우리 CD 접근 = 0 인데 깜빡임      CD 경합은 원인이 아니다.
--                                            0.1.1 의 상관관계는 우연이었다.
--                                            -> 라스터/VDC 계측으로 넘어간다
--   재생 중에도 우리 CD 접근이 남아 있음      선적재가 실제로는 안 먹었다.
--                                            실험 자체가 무효 -> 빌드를 고친다
--
-- 이 구분을 안 하고 "실패"로 넘기면, 멀쩡한 가설을 잘못된 근거로 버리게 된다.
--
-- 같이 보는 것
-- ------------
--   게임 자신의 스트리밍 주기가 여전히 13~14 로 고른가.  선적재 뒤에도 주기가
--   깨진다면 그 원인은 우리 CD 접근이 아니라 다른 데 있다.
--
-- 쓰는 법
-- -------
--   1) **0.3.3-preload** 디스크 -> 이 스크립트 Run   (주소가 이 디스크 전용이다)
--   2) 첫 한글 문자열에서 긴 초기 적재가 한 번 지나간다.  그건 정상이다
--   3) 폐공장에서 UI 진입 / UI->세부 UI / 대사 / 대사 후 UI 복귀 를 왕복
--   4) Stop  (Stop 해야 census 가 남는다)
--   5) dump\ui_load_v12_*.tsv 를 넘긴다
--
-- 읽는 법
-- -------
--   kind=init     초기 선적재.  한 번만 나와야 한다
--   kind=pack     재생 중 팩 적재.  **선적재가 먹었다면 여기가 0 건이어야 한다**
--   kind=frame    CD 활동이나 헬퍼 활동이 있던 프레임
--   kind=census   정지 시 누적

local mem = emu.memType.pceMemory
local cpu = emu.memType.cpu
local OUT = string.format("C:\\snatcher\\dump\\ui_load_v12_%s.tsv", os.date("%H%M%S"))

-- build\patch\0.3.3-preload\helper_symbols.json.  **0.1.1 과 주소가 다르다** --
-- 헬퍼가 713 -> 714 B 로 바뀌면서 전부 1 씩 밀렸다.  디스크를 바꾸면 반드시
-- 심볼 파일을 다시 보고 이 블록을 갱신할 것.
local HELPER       = 0xBCD2
local INIT_STORE   = 0xBCEF   -- 초기 선적재 진입 (전원 사이클당 1회여야 한다)
local LOAD_PACKAGE = 0xBD95   -- 재생 중 팩 적재.  선적재가 먹었으면 안 불려야 한다
local COPY_RECORD  = 0xBDEA
local RETURN_MISS  = 0xBEA8
local LOAD_BLOB    = 0xBEB7
local BIOS_CD_READ = 0xE009
local BIOS_CD_BASE = 0xE006
local PACK_ID      = 0xBFE8   -- 스크래치 = HELPER_LIMIT($C000) - $20, +8

local PACK = {[0]="speaker", [1]="ui", [2]="small_scenes", [3]="shared",
  [4]="scene_0C9800", [5]="scene_0BB800", [6]="scene_110000", [7]="scene_119800",
  [8]="scene_121800", [9]="scene_0BC000", [10]="scene_111800", [11]="scene_10F800",
  [12]="scene_17B800", [13]="scene_0BA000", [14]="scene_0CF800", [15]="scene_117800",
  [16]="scene_0D1800", [17]="scene_112000", [18]="scene_0E7800", [19]="scene_1B5000",
  [20]="scene_110800", [21]="scene_10F000", [22]="scene_179800", [23]="scene_111000",
  [24]="scene_160800"}

-- 레코드 1건의 비용.  helper_symbols.json 의 cost_cycles 와 같다.
-- 프레임 단위로 재면 이 현상이 안 보인다 -- 3건이 몰려도 프레임의 0.19 라서
-- "예산 초과"에는 안 걸린다.  그런데 TAI 하나(8 스캔라인)가 눈에 띄었던 것을
-- 생각하면 49 스캔라인은 이미 큰 값이다.  그래서 눈금을 스캔라인으로 바꾼다.
local COST_MIN = 3784 + 593           -- 템플릿(76x8) + 텍스트
local COST_MAX = COST_MIN + 209 * 15  -- + 글리프 슬롯 최대
local LINE_CYCLES = 455               -- 7.16 MHz / 15.7 kHz

local file = assert(io.open(OUT, "w"))
file:write("kind\tframe\tgap\tcalls\tcopies\tmisses\tpackloads\tcdreads\tcdseeks\t" ..
           "lines_min\tlines_max\tpack_id\tpack_name\tnote\n")
file:flush()

local frame = 0
local calls, copies, misses, packloads, cdreads, cdseeks = 0, 0, 0, 0, 0, 0
local total = { calls=0, copies=0, misses=0, packloads=0, cdreads=0, cdseeks=0 }
local initRuns, playLoads = 0, 0
local lastRead = nil          -- 게임 스트리밍 주기 측정용
local closed = false

local function row(kind, packId, gap, note)
  if closed then return end
  file:write(string.format(
    "%s\t%d\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%.0f\t%.0f\t%s\t%s\t%s\n",
    kind, frame, gap and tostring(gap) or "-",
    calls, copies, misses, packloads, cdreads, cdseeks,
    copies * COST_MIN / LINE_CYCLES, copies * COST_MAX / LINE_CYCLES,
    packId and tostring(packId) or "-",
    packId and (PACK[packId] or "?") or "-", note or ""))
  file:flush()
end

local function counter(address, bump)
  emu.addMemoryCallback(bump, emu.callbackType.exec, address, address,
    emu.cpuType.pce, cpu)
end

counter(HELPER,       function() calls = calls + 1 end)
counter(COPY_RECORD,  function() copies = copies + 1 end)
counter(RETURN_MISS,  function() misses = misses + 1 end)
counter(LOAD_BLOB,    function() packloads = packloads + 1 end)
counter(BIOS_CD_READ, function() cdreads = cdreads + 1 end)
counter(BIOS_CD_BASE, function() cdseeks = cdseeks + 1 end)

counter(INIT_STORE, function()
  initRuns = initRuns + 1
  row("init", nil, nil, string.format(
    "선적재 %d회째 (1회여야 정상)", initRuns))
  emu.log(string.format("INIT STORE f%d  (%d회째)", frame, initRuns))
end)

-- 이 프로브의 존재 이유.  선적재가 먹었다면 여기는 한 번도 안 불려야 한다.
counter(LOAD_PACKAGE, function()
  playLoads = playLoads + 1
  local id = emu.read(PACK_ID, mem)
  local bad = (id == nil) or (id < 0) or (id > 24)
  row("pack", bad and nil or id, nil,
    bad and string.format("PACK_ID 읽기 실패 (raw=%s)", tostring(id))
         or "재생 중 팩 적재 -- 선적재가 안 먹었다")
  emu.log(string.format("PLAY LOAD f%d  id=%s %s  <<< 선적재 실패",
    frame, tostring(id), (not bad) and (PACK[id] or "?") or "BAD"))
end)

-- E = 뜸들인 순간 표시.
-- "메뉴가 버벅인 바로 그 순간"이 로그의 어느 프레임인지는 이것 없이는 못 맞춘다.
--
-- F5 는 쓰지 말 것 -- **Mesen 의 세이브 스테이트 저장 키와 겹쳐서** 마커를 누를
-- 때마다 스테이트가 덮어써진다.  F1-F10 은 전부 스테이트 슬롯 계열이다.
--
-- 30프레임 이내 연타는 한 번으로 친다.
local lastMark = 0

emu.addEventCallback(function()
  frame = frame + 1
  if emu.isKeyPressed("E") and (lastMark == 0 or frame - lastMark > 30) then
    lastMark = frame
    row("MARK", nil, nil, "여기서 버벅였다")
    emu.log(string.format("---- MARK f%d ----", frame))
  end
  if calls > 0 or cdreads > 0 or cdseeks > 0 then
    total.calls = total.calls + calls
    total.copies = total.copies + copies
    total.misses = total.misses + misses
    total.packloads = total.packloads + packloads
    total.cdreads = total.cdreads + cdreads
    total.cdseeks = total.cdseeks + cdseeks
    local gap = nil
    if cdreads > 0 then
      gap = lastRead and (frame - lastRead) or nil
      lastRead = frame
    end
    -- 게임 스트리밍은 13~14 프레임이 정상.  20 이상이면 누군가 방해한 것이다.
    local note = ""
    if gap and gap >= 20 then note = string.format("주기 이탈 (%d프레임)", gap) end
    -- 항목이 많은 UI 를 그리는 순간을 눈에 띄게 남긴다.  사용자 관측이
    -- "UI 개수가 많을수록 심하다" 이므로 이 값이 증상과 같이 가야 한다.
    if copies >= 3 then
      -- 나눗셈 결과는 Lua 5.4 에서 실수다.  %d 는 정수 표현이 없는 값을 거부하므로
      -- 반드시 %.0f 로 찍는다 (row() 도 같은 이유로 %.0f 를 쓴다).
      note = note .. string.format("%s레코드 %d건 = %.0f~%.0f 스캔라인",
        note ~= "" and " · " or "", copies,
        copies * COST_MIN / LINE_CYCLES, copies * COST_MAX / LINE_CYCLES)
    end
    row("frame", nil, gap, note)
  end
  calls, copies, misses, packloads, cdreads, cdseeks = 0, 0, 0, 0, 0, 0
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  calls, copies, misses = total.calls, total.copies, total.misses
  packloads, cdreads, cdseeks = total.packloads, total.cdreads, total.cdseeks
  frame = 0
  row("census", nil, nil, string.format(
    "선적재 %d회 · 재생 중 팩적재 %d건 %s",
    initRuns, playLoads,
    playLoads == 0 and "(0건 = 선적재 성공, CD 경합은 무죄)"
                   or "(0건이 아님 = 선적재가 안 먹었다)"))
  closed = true
  file:close()
  emu.log(string.format(
    "PROBE_UI_LOAD 0.1.2: init %d · playLoad %d · cdread %d · cdseek %d -> %s",
    initRuns, playLoads, total.cdreads, total.cdseeks, OUT))
end, emu.eventType.scriptEnded)

emu.log("PROBE_UI_LOAD 0.1.2 loaded  (**0.3.3-preload 전용 주소**)")
emu.log("  버벅인 순간마다 E 키 (F5 는 세이브 스테이트라 안 씀)")
emu.log("  핵심: kind=pack 이 0건이면 선적재 성공 -> CD 경합은 원인이 아니다")
emu.log("  0건이 아니면 선적재가 안 먹은 것이고 실험이 무효다")
emu.log("  Stop 해야 census 가 남는다.  출력: " .. OUT)
