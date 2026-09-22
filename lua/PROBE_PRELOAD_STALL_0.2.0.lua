-- PROBE_PRELOAD_STALL 0.2.0 - 선택적 선적재의 부팅 시간과 팩 스톨을 잰다
--
-- 왜 새 프로브인가
-- ----------------
-- PROBE_UI_LOAD 0.1.x 는 "재생 중 우리 CD 접근이 0 인가"를 물었고, 답은 나왔다
-- (0 인데도 깜빡였다 -> CD 경합 기각).  이 프로브는 **다른 질문**을 한다.
--
--   0.3.4 는 25개 팩을 전부 선적재해 재생 중 CD 를 0 으로 만들었지만, 그 대가로
--   부팅에서 52 청크(약 9.8 초)를 읽는다.  공용 4팩만 올리면 35 청크로 줄지만
--   scene 팩 21개가 수요적재로 돌아간다.
--
--   물음 1  부팅 적재가 실제로 몇 프레임인가            (환산 188 ms/호출은 추정치다)
--   물음 2  scene 팩 첫 접근에서 실제로 몇 프레임 멈추나
--   물음 3  그 멈춤이 게임 자신의 CD 스트리밍을 밀어내나
--
-- 세 번째가 중요하다.  0.1.1 에서 우리 적재가 게임의 읽기 주기를 13 -> 22~30
-- 프레임으로 민 것이 5건 중 5건이었다.  깜빡임의 원인은 아니었지만 **로딩 체감의
-- 원인일 수는 있다.**  둘은 다른 문제다.
--
-- 고치지 않는다
-- -------------
-- 이 프로브는 계측만 한다.  숫자를 보고 판단하는 것은 사람이다.
--
-- 쓰는 법
-- -------
--   1) 아래 BUILD 를 지금 돌릴 디스크에 맞춘다.  **틀리면 전부 헛 계측이다**
--   2) 전원 사이클에서 시작한다 (부팅 적재는 파워사이클당 1회다)
--   3) 평소처럼 논다.  장소를 옮길수록 좋다 -- 팩 첫 접근이 거기서 난다
--   4) 멈칫한 순간마다 E 키.  로그의 어느 프레임인지 이것 없이는 못 맞춘다
--   5) Stop  (Stop 해야 census 가 남는다)
--
-- 읽는 법
-- -------
--   kind=boot      부팅 적재.  파워사이클당 1회.  frames/seconds 가 답이다
--   kind=packstall scene 팩 첫 접근.  frames 가 플레이어가 느끼는 멈춤이다
--   kind=cdgap     우리 적재가 끼어든 구간의 게임 CD 읽기 간격.  우리가 안
--                  끼어든 간격은 게임 사정이라 아예 찍지 않는다
--   kind=census    정지 시 누적.  팩별 첫 접근 프레임 포함

local mem = emu.memType.pceMemory
local cpu = emu.memType.cpu

-- ---------------------------------------------------------------- 빌드 선택
-- helper_symbols.json 에서 그대로 옮긴 값이다.  디스크를 다시 빌드하면 헬퍼가
-- 움직이므로 반드시 다시 대조할 것 -- preall(713 B) 과 preresident(723 B) 가
-- init_ok 이후로 정확히 10 바이트씩 어긋나 있는 것이 그 예다.
local BUILD = "prenone"     -- "prenone" | "preresident" | "preall"

-- init_store 와 init_ok 는 세 빌드가 모두 같다 (플래그 루프 앞이라 안 밀린다).
-- 그래서 BUILD 를 틀려도 부팅 시간만은 맞게 나온다 -- 실제로 prenone 디스크를
-- preresident 설정으로 돌린 판에서 부팅 5.27초는 유효했고, 11바이트 밀린
-- blob_failed 훅이 엉뚱한 명령을 잡아 "BLOB FAILED" 를 세 번 뱉었다.
-- 경고가 뜨면 부팅 값만 믿고 나머지는 버릴 것.
local SYMBOLS = {
  prenone = {       -- build\patch\0.3.4-prenone\helper_symbols.json (헬퍼 712 B)
    INIT_STORE = 0xBCEF, INIT_OK = 0xBD1C, LOOKUP = 0xBD3A,
    LOAD_PACKAGE = 0xBD94, PACK_LOADED = 0xBDDA, COPY_RECORD = 0xBDE9,
    RETURN_MISS = 0xBEA6, LOAD_BLOB = 0xBEB5, BLOB_FAILED = 0xBF43,
  },
  preresident = {   -- build\patch\0.3.4-preresident\helper_symbols.json
    INIT_STORE = 0xBCEF, INIT_OK = 0xBD1C, LOOKUP = 0xBD45,
    LOAD_PACKAGE = 0xBD9F, PACK_LOADED = 0xBDE5, COPY_RECORD = 0xBDF4,
    RETURN_MISS = 0xBEB1, LOAD_BLOB = 0xBEC0, BLOB_FAILED = 0xBF4E,
  },
  preall = {        -- build\patch\0.3.4-preall\helper_symbols.json
    INIT_STORE = 0xBCEF, INIT_OK = 0xBD1C, LOOKUP = 0xBD3B,
    LOAD_PACKAGE = 0xBD95, PACK_LOADED = 0xBDDB, COPY_RECORD = 0xBDEA,
    RETURN_MISS = 0xBEA7, LOAD_BLOB = 0xBEB6, BLOB_FAILED = 0xBF44,
  },
}
local S = assert(SYMBOLS[BUILD], "BUILD 이름이 SYMBOLS 에 없다: " .. tostring(BUILD))

local BIOS_CD_READ = 0xE009
local BIOS_CD_BASE = 0xE006

-- 스크래치는 케이브 마지막 $20 바이트다 (HELPER_LIMIT $C000 - $20).
-- 순서: CUR_LO CUR_HI LEFT FINAL_LO DEST_LO DEST_MID DEST_HI STATUS PACK_ID ...
local SCRATCH  = 0xC000 - 0x20
local LEFT     = SCRATCH + 2    -- 남은 8 KiB 청크 수.  부팅 적재의 진행도다
local PACK_ID  = SCRATCH + 8

local PACK = {[0]="speaker", [1]="ui", [2]="small_scenes", [3]="shared",
  [4]="scene_0C9800", [5]="scene_0BB800", [6]="scene_110000", [7]="scene_119800",
  [8]="scene_121800", [9]="scene_0BC000", [10]="scene_111800", [11]="scene_10F800",
  [12]="scene_17B800", [13]="scene_0BA000", [14]="scene_0CF800", [15]="scene_117800",
  [16]="scene_0D1800", [17]="scene_112000", [18]="scene_0E7800", [19]="scene_1B5000",
  [20]="scene_110800", [21]="scene_10F000", [22]="scene_179800", [23]="scene_111000",
  [24]="scene_160800"}

local OUT = string.format("C:\\snatcher\\dump\\preload_stall_v020_%s_%s.tsv",
                          BUILD, os.date("%H%M%S"))
local file = assert(io.open(OUT, "w"))
file:write("kind\tframe\tframes\tseconds\tpack_id\tpack_name\t" ..
           "chunks\tcdreads\tcdseeks\tgap\tnote\n")
file:flush()

local frame   = 0
local closed  = false

-- 부팅 적재
local bootStart, bootChunks, bootDone = nil, nil, false
-- 팩 적재 (한 번에 하나만 진행한다 -- 헬퍼가 재진입하지 않는다)
local packStart, packId = nil, nil
-- 게임 자신의 CD 주기
local lastRead = nil
-- 직전 CD 읽기 이후 우리가 적재한 횟수.  이것이 0 이면 간격은 게임 사정이다.
local loadsSinceRead = 0
-- 누적
local cdreads, cdseeks = 0, 0
local frameReads = 0
local firstTouch = {}    -- pack_id -> 첫 접근 프레임
local stalls = {}        -- pack_id -> {n=, frames=}
local playLoads = 0

local function row(kind, frames, packIdArg, chunks, gap, note)
  if closed then return end
  file:write(string.format("%s\t%d\t%s\t%s\t%s\t%s\t%s\t%d\t%d\t%s\t%s\n",
    kind, frame,
    frames and tostring(frames) or "-",
    -- Lua 5.4 는 정수 표현이 없는 실수를 %d 로 못 찍는다.  나눗셈은 전부 %.2f/%.0f
    frames and string.format("%.2f", frames / 60.0) or "-",
    packIdArg and tostring(packIdArg) or "-",
    packIdArg and (PACK[packIdArg] or "?") or "-",
    chunks and tostring(chunks) or "-",
    cdreads, cdseeks,
    gap and tostring(gap) or "-",
    note or ""))
  file:flush()
end

local function hook(address, fn)
  emu.addMemoryCallback(fn, emu.callbackType.exec, address, address,
    emu.cpuType.pce, cpu)
end

-- ------------------------------------------------------------- 부팅 적재
-- init_store 는 LEFT 에 청크 수를 써넣기 **직전**이므로, 여기서 읽으면 이전
-- 값이다.  다음 프레임에 읽어야 이번 적재의 청크 수가 나온다.
hook(S.INIT_STORE, function()
  bootStart, bootDone, bootChunks = frame, false, nil
  row("boot", nil, nil, nil, nil, "부팅 적재 시작 (파워사이클당 1회여야 정상)")
  emu.log(string.format("BOOT LOAD start f%d", frame))
end)

hook(S.INIT_OK, function()
  if bootStart == nil or bootDone then return end
  bootDone = true
  local n = frame - bootStart
  row("boot", n, nil, bootChunks, nil, string.format(
    "부팅 적재 완료 -- %d 프레임 = %.2f 초", n, n / 60.0))
  emu.log(string.format("BOOT LOAD done  f%d  %d frames = %.2fs", frame, n, n / 60.0))
end)

-- ------------------------------------------------------------- 팩 수요적재
-- 선적재가 "all" 이면 여기는 한 번도 안 불려야 한다.  "resident" 면 scene 팩
-- 첫 접근마다 불린다 -- 그 프레임 수가 이 프로브의 핵심 값이다.
hook(S.LOAD_PACKAGE, function()
  playLoads = playLoads + 1
  local id = emu.read(PACK_ID, mem)
  if id == nil or id < 0 or id > 24 then id = nil end
  packStart, packId = frame, id
  loadsSinceRead = loadsSinceRead + 1
  if id and firstTouch[id] == nil then firstTouch[id] = frame end
end)

-- 적재가 끝나고 레코드 재구성으로 넘어가는 지점.  플레이어가 느끼는 멈춤은
-- load_package 진입부터 여기까지다.
hook(S.PACK_LOADED, function()
  if packStart == nil then return end
  local n = frame - packStart
  local id = packId
  if id then
    local s = stalls[id] or {n = 0, frames = 0}
    s.n, s.frames = s.n + 1, s.frames + n
    stalls[id] = s
  end
  row("packstall", n, id, nil, nil, string.format(
    "팩 첫 접근 멈춤 %d 프레임 = %.2f 초", n, n / 60.0))
  if n >= 6 then
    emu.log(string.format("PACK STALL f%d  id=%s %s  %d frames = %.2fs",
      frame, tostring(id), id and (PACK[id] or "?") or "?", n, n / 60.0))
  end
  packStart, packId = nil, nil
end)

hook(S.BLOB_FAILED, function()
  row("error", nil, packId, nil, nil, "load_blob 실패 -- 적재가 안 됐다")
  emu.log(string.format("BLOB FAILED f%d", frame))
  packStart, packId = nil, nil
end)

hook(BIOS_CD_READ, function()
  cdreads = cdreads + 1
  frameReads = frameReads + 1
end)
hook(BIOS_CD_BASE, function() cdseeks = cdseeks + 1 end)

-- ------------------------------------------------------------------ 프레임
local lastMark = 0

emu.addEventCallback(function()
  frame = frame + 1

  -- 부팅 적재가 도는 동안 LEFT 를 한 번 캐 둔다 (init_store 시점엔 아직 안 써졌다)
  if bootStart and not bootDone and bootChunks == nil and frame > bootStart then
    local v = emu.read(LEFT, mem)
    if v and v > 0 then bootChunks = v end
  end

  -- E = 멈칫한 순간.  F5 는 Mesen 세이브 스테이트라 쓰지 않는다.
  if emu.isKeyPressed("E") and (lastMark == 0 or frame - lastMark > 30) then
    lastMark = frame
    row("MARK", nil, nil, nil, nil, "여기서 멈칫했다")
    emu.log(string.format("---- MARK f%d ----", frame))
  end

  -- 게임 자신의 CD 읽기 주기.
  --
  -- 0.2.0 초판은 "20 프레임 이상이면 이탈"로 찍었다.  13~14 프레임 주기는
  -- **폐공장 스트리밍 전용** 값인데 그것을 전 구간에 적용한 탓에, 수백 프레임
  -- 간격이 정상인 곳에서 읽기마다 경고가 나와 파일이 그것으로 도배됐다.
  --
  -- 애초에 이 줄의 목적은 "우리 팩 적재가 게임 읽기를 밀어냈는가" 하나다.
  -- 그러니 직전 읽기와 이번 읽기 사이에 우리 적재가 **실제로 있었을 때만**
  -- 남긴다.  우리가 안 끼어든 구간의 간격은 게임 사정이라 볼 이유가 없다.
  if frameReads > 0 then
    local gap = lastRead and (frame - lastRead) or nil
    if gap and loadsSinceRead > 0 then
      row("cdgap", nil, nil, nil, gap, string.format(
        "직전 읽기 이후 우리 적재 %d회 · 간격 %d 프레임", loadsSinceRead, gap))
    end
    lastRead = frame
    loadsSinceRead = 0
    frameReads = 0
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  local touched, worst, worstId = 0, 0, nil
  for id, f in pairs(firstTouch) do
    touched = touched + 1
    local s = stalls[id]
    row("census", s and s.frames or nil, id, nil, nil, string.format(
      "첫 접근 f%d · 적재 %d회 · 누적 %d 프레임", f, s and s.n or 0, s and s.frames or 0))
    if s and s.frames > worst then worst, worstId = s.frames, id end
  end
  row("census", nil, nil, nil, nil, string.format(
    "빌드 %s · 수요적재 %d회 · 팩 %d종 · 최대 %s %d프레임 · cdread %d · cdseek %d",
    BUILD, playLoads, touched,
    worstId and (PACK[worstId] or "?") or "-", worst, cdreads, cdseeks))
  closed = true
  file:close()
  emu.log(string.format(
    "PROBE_PRELOAD_STALL 0.2.0 [%s]: 수요적재 %d회 · 팩 %d종 -> %s",
    BUILD, playLoads, touched, OUT))
end, emu.eventType.scriptEnded)

-- 어느 디스크가 올라와 있는지 스스로 찍는다.  BUILD 는 사람이 손으로 맞추는
-- 값이라 틀리기 쉽고, 틀리면 파일 이름만 그럴듯하고 주소는 남의 것이 된다
-- (실제로 [KO 0.3.4] 를 preresident 라는 이름으로 한 판 기록했다).
-- 이름이 로그 첫 줄에 있으면 나중에 그 파일만 보고도 판별된다.
local romName = "?"
do
  local ok, info = pcall(emu.getRomInfo)
  if ok and info then romName = info.name or info.path or "?" end
end
local matches = romName:find(BUILD, 1, true) ~= nil
emu.log(string.format("PROBE_PRELOAD_STALL 0.2.0 loaded  (BUILD=%s)", BUILD))
emu.log("  디스크: " .. tostring(romName))
if not matches then
  emu.log("  *** 경고: 디스크 이름에 BUILD 문자열이 없다.  주소가 안 맞을 수 있다 ***")
end
row("disc", nil, nil, nil, nil, string.format(
  "BUILD=%s · 디스크=%s%s", BUILD, romName,
  matches and "" or "  <<< 불일치 의심"))
emu.log("  BUILD 가 지금 돌리는 디스크와 다르면 전부 헛 계측이다")
emu.log("  파워사이클에서 시작할 것 -- 부팅 적재는 사이클당 1회다")
emu.log("  멈칫한 순간마다 E 키 (F5 는 세이브 스테이트)")
emu.log("  Stop 해야 census 가 남는다.  출력: " .. OUT)
