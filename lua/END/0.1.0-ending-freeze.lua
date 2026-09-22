-- END 0.1.0 -- 엔딩 스크롤 뒤 타이틀로 못 돌아가고 멈추는 것을 잡는다
--
-- ★ 순수 관측.  아무것도 안 쓰고 화면에도 안 그린다.
--
-- 왜 새로 만드나
-- --------------
-- 이 증상은 **한 번도 조사된 적이 없다** (2026-09-05 문서 전수 확인).
-- "엔딩" 으로 걸리는 기록은 전부 음성 클립 미수집 얘기고, "타이틀 복귀" 는
-- 2026-08-13 의 세이브 후 화면 깨짐이라 다른 건이다.
--
-- 다만 **비슷한 멈춤을 잡은 전례가 있다.**  `lua/PROBE_CRASH_WATCH_0.1.4.lua`
-- 가 조이 디비전 정지를 잡았고 그때 이렇게 나왔다:
--
--     activeIrqs $1C · enabledIrqs $00
--     -> CD 인터럽트가 떠 있는데 전부 마스크됨.  게임이 영원히 안 깨어난다
--
-- 그래서 그 프로브의 **좋은 부분을 그대로 가져온다** -- 수동 덤프 키, IRQ
-- 레지스터 기록, 링 버퍼.  자동 감지만 이 증상에 맞게 바꾼다.
--
-- 무엇으로 "멈췄다" 를 아나
-- -------------------------
-- `$201B` 는 게임의 VBlank 처리가 올리는 프레임 시계다 (자막이 이걸로 시각을
-- 잰다).  에뮬 프레임은 도는데 **이것이 안 오르면** 게임이 멈춘 것이다.
-- IRQ 가 막혀 안 깨어나는 경우도 여기에 잡힌다.
--
-- 무엇을 남기나
-- ------------
-- ```
-- $201B   게임 프레임 시계     안 오르면 멈춘 것
-- PC · SP                     어디서 도는가.  ★s["cpu.pc"] 로 읽는다
--                             (s.cpu.pc 는 nil 이다 -- GFX 0.1.1 에서 밟았다)
-- $1802   IRQ 허용
-- $1803   IRQ 상태            $1802 가 0 인데 $1803 에 비트가 서 있으면 그 함정이다
-- $7FDF   우리 자막 STATE      엔딩에 우리 코드가 걸려 있었나
-- ```
--
-- 멈추기 직전 40 프레임이 남는다.  거기서 갈린다.
--
--     우리 STATE 가 돌고 있었다   -> 우리 쪽을 먼저 판다
--     한참 전에 끝났고 게임만 돌았다 -> 원작/CD 타이밍 쪽
--
-- ⚠ 먼저 해볼 것 (이 프로브보다 싸다)
-- ----------------------------------
--     원본 디스크로도 엔딩에서 멈추나
--     -> 멈추면 우리 탓이 아니다.  조사 범위가 반으로 준다
--
-- 쓰는 법
-- -------
--   1) 이 스크립트를 연다
--   2) 엔딩까지 간다 (세이브스테이트로 엔딩 직전까지 가도 된다 --
--      ⚠ 단 **우리 빌드에서 뜬 스테이트**여야 한다.  §25 참고)
--   3) 멈추면 자동으로 덤프된다.  안 되면 아래 키를 누른다
--
-- 산출물  C:/snatcher/dump/end_freeze_0_1_0_<시각>.tsv

local MEM = emu.memType.pceMemory

local CLOCK = 0x201B          -- 게임 프레임 시계 (VBlank 가 올린다)
local STATE = 0x7FDF          -- 우리 자막 STATE
local IRQ_MASK, IRQ_STATUS = 0x1802, 0x1803

local RING = 40               -- 남길 프레임 수
local STALL_FRAMES = 120      -- 시계가 이만큼 안 오르면 멈춘 것으로 본다

local stamp = "session"
if os ~= nil and os.date ~= nil then stamp = os.date("%Y%m%d_%H%M%S") end
local PATH = "C:/snatcher/dump/end_freeze_0_1_0_" .. stamp .. ".tsv"

local function say(m) emu.log(m); print(m) end

-- 덤프 키를 찾는다.  F1 은 로드스테이트라 못 쓴다 (0.1.4 에서 소유자가 겪었다).
local DUMP_KEYS = { "E", "e", "KeyE", "D", "d", "Q", "q", "R", "T", "G", "H" }
local dumpKey = nil
for _, name in ipairs(DUMP_KEYS) do
  local ok, value = pcall(function() return emu.isKeyPressed(name) end)
  if ok and type(value) == "boolean" then dumpKey = name break end
end

local ring, ringAt = {}, 0
local frame, dumped = 0, 0
local lastClock, stalled = nil, 0

local function sample()
  local ok, s = pcall(emu.getState)
  if not ok then s = nil end
  return {
    frame = frame,
    clock = emu.read(CLOCK, MEM) or -1,
    pc = (s and s["cpu.pc"]) or -1,
    sp = (s and s["cpu.sp"]) or -1,
    state = emu.read(STATE, MEM) or -1,
    mask = emu.read(IRQ_MASK, MEM) or -1,
    status = emu.read(IRQ_STATUS, MEM) or -1,
  }
end

local function dump(reason)
  dumped = dumped + 1
  local f = io.open(PATH, "w")
  if f == nil then say("파일 열기 실패: " .. PATH); return end
  f:write("# 사유\t" .. reason .. "\n")
  f:write("# 프레임\t" .. frame .. "\n")
  f:write("frame\tclock\tpc\tsp\tstate\tirq_mask\tirq_status\n")
  for offset = 1, RING do
    local entry = ring[((ringAt + offset - 1) % RING) + 1]
    if entry ~= nil then
      f:write(string.format("%d\t%02X\t%04X\t%02X\t%02X\t%02X\t%02X\n",
                            entry.frame, entry.clock % 256, entry.pc % 0x10000,
                            entry.sp % 256, entry.state % 256,
                            entry.mask % 256, entry.status % 256))
    end
  end
  f:close()
  say("")
  say("★덤프 -- " .. reason)
  local last = ring[((ringAt - 1) % RING) + 1]
  if last ~= nil then
    say(string.format("  PC $%04X · SP $%02X · STATE $%02X",
                      last.pc % 0x10000, last.sp % 256, last.state % 256))
    say(string.format("  IRQ 허용 $%02X · 상태 $%02X", last.mask % 256, last.status % 256))
    if last.mask == 0 and last.status ~= 0 then
      say("  ★IRQ 가 떠 있는데 전부 마스크됐다 -- 안 깨어나는 그 함정이다")
    end
  end
  say("  " .. PATH)
end

emu.addEventCallback(function()
  frame = frame + 1
  local entry = sample()
  ringAt = (ringAt % RING) + 1
  ring[ringAt] = entry

  -- 게임 시계가 멈췄나
  if lastClock ~= nil and entry.clock == lastClock then
    stalled = stalled + 1
    if stalled == STALL_FRAMES then
      dump(string.format("게임 시계($201B)가 %d 프레임 동안 안 올랐다", STALL_FRAMES))
    end
  else
    if stalled >= STALL_FRAMES then
      say(string.format("  f%d  시계가 다시 돈다 (멈춤 %d 프레임)", frame, stalled))
    end
    stalled = 0
  end
  lastClock = entry.clock

  if dumpKey ~= nil then
    local ok, down = pcall(function() return emu.isKeyPressed(dumpKey) end)
    if ok and down then dump("손으로 눌렀다 (" .. dumpKey .. ")") end
  end

  if frame % 900 == 0 then
    say(string.format("f%d  시계 $%02X · STATE $%02X · IRQ %02X/%02X",
                      frame, entry.clock % 256, entry.state % 256,
                      entry.mask % 256, entry.status % 256))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if dumped == 0 then
    dump("스크립트를 멈췄다")
  end
  say(string.format("끝 -- 덤프 %d 회", dumped))
end, emu.eventType.scriptEnded)

say("END 0.1.0 -- 엔딩까지 가라.  멈추면 자동으로 덤프한다")
say("  수동 덤프 키: " .. (dumpKey or "없음 (자동/Stop 만)"))
say("  " .. PATH)
