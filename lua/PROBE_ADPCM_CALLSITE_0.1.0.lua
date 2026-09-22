-- PROBE ADPCM호출지점 0.1.0 -- 게임이 **어디서** 음성 재생을 거는가
--
-- 왜 필요한가
-- ---------------------------------------------------------------------------
-- 지금까지 모은 음성 320행(voice_events.tsv)은 호출 지점이 아니다.
-- `runtime_text_audit_0.2.1.lua` 는 오디오를 **훅하지 않고** 매 프레임
-- 에뮬레이터 상태를 읽는다:
--
--     state["cdrom.adpcm.playing"] · readAddress · writeAddress · adpcmLength
--
-- addMemoryCallback 은 전부 텍스트 경로에만 걸려 있다 ($6FFD $5E40 $360D/E
-- $66E5 $66E8).  그래서 PC 가 기록될 수 없었다.
--
-- 그리고 그것이 **지문이 흔들리는 이유와 같은 원인**이다.  재생 시작 뒤 몇
-- 프레임 지나 읽으면 읽기 포인터가 전진해 있어서 같은 클립이 여러 지문으로
-- 갈린다 (SUBTITLE_OVERLAY_0.1.2 가 147종->26종으로 정리한 그 문제.  현재
-- 캡처는 320행 -> 끝주소 기준 40클립).
--
-- 포트 쓰기에 훅을 걸면 둘 다 한 번에 풀린다:
--     (1) 쓰는 코드의 PC = yunatools 가 후킹하는 "ADPCM playback entry point"
--     (2) 시작 시점의 레지스터 = 드리프트 없는 진짜 신원
--
-- 무엇을 재나
-- ---------------------------------------------------------------------------
--     $1800-$180F 쓰기마다  주소 · 값 · **PC** · 그 PC 가 사는 뱅크(MPR) · 프레임
--     PC 별 집계            어느 지점이 진짜 재생 진입인지 (여러 곳일 수 있다)
--     클립 시작 묶음        짧은 시간 안에 몰린 쓰기를 한 덩어리로 묶어 기록
--
-- yunatools 대조 (docs\REFERENCE_YUNATOOLS_SUBTITLES.md)
-- ---------------------------------------------------------------------------
-- yuna 는 ADPCM 재생 진입점에서 오디오 이벤트 카운터를 올리고 시작 프레임을
-- 기억한다.  우리도 같은 자리가 필요하다.  단 yuna 의 주소는 그 게임 것이라
-- 그대로 못 쓴다 -- 그래서 이 프로브로 **우리 게임의 자리**를 찾는다.
--
-- POC 대상 장면 (소유자 지정)
-- ---------------------------------------------------------------------------
--     _0003  길리언  "금일부로 JUNKER로 임명된 길리언 시드다."  3.317초  섹터 $003078
--     _0004  미카    "길리언 시드님．"                         2.800초  섹터 $003083
--     직전 문맥: <원문 7자>、<원문 9자>。
--
-- 돌리는 법
-- ---------------------------------------------------------------------------
--   디스크  build\patch\0.4.5\...(0818-2216).cue   (아무 판이나 되지만 정식으로)
--   그 장면 **직전**에서 켜고, 두 대사가 다 나올 때까지 두었다가 정지.
--   음성이 한 번도 안 나오면 아무것도 안 잡힌다 -- 화면의 `쓰기 N` 이 올라가야 한다.
--
--   출력: C:\snatcher\dump\probe_adpcm_callsite_0_1_0.tsv

local OUT = "C:\\snatcher\\dump\\probe_adpcm_callsite_0_1_0.tsv"
local mem = emu.memType.pceMemory

local IO_LO, IO_HI = 0x1800, 0x180F
local GROUP_GAP = 8            -- 이 프레임 수 안에 이어지면 한 클립 시작으로 묶는다
local LOG_MAX = 400

local file = assert(io.open(OUT, "w"))
file:write("kind\tframe\tport\tvalue\tpc\tbank\tplaying\tnote\n")

local frame, writes, logged = 0, 0, 0
local pcTally, portTally = {}, {}
local lastWriteFrame, groupOpen = -99, false
local groups = 0

local function state()
  local ok, s = pcall(emu.getState)
  if not ok then return nil end
  return s
end

local function row(kind, port, value, pc, bank, playing, note)
  file:write(string.format("%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\n",
    kind, frame,
    port and string.format("%04X", port) or "",
    value and string.format("%02X", value) or "",
    pc and string.format("%04X", pc) or "",
    bank and string.format("%02X", bank) or "",
    playing == nil and "" or tostring(playing),
    note or ""))
  file:flush()
end

emu.addMemoryCallback(function(address, value)
  writes = writes + 1
  local s = state()
  local pc, bank, playing
  if s then
    pc = s["cpu.pc"]
    if pc then
      local slot = math.floor(pc / 0x2000)
      bank = s[string.format("memoryManager.mpr[%d]", slot)]
      if bank == nil then bank = s[string.format("mpr[%d]", slot)] end
    end
    playing = s["cdrom.adpcm.playing"]
  end

  if pc then pcTally[pc] = (pcTally[pc] or 0) + 1 end
  portTally[address] = (portTally[address] or 0) + 1

  -- 클립 시작 묶기: 한동안 조용하다가 다시 쓰기가 시작되면 새 덩어리다
  if frame - lastWriteFrame > GROUP_GAP then
    groups = groups + 1
    groupOpen = true
    if logged < LOG_MAX then
      logged = logged + 1
      row("start", address, value, pc, bank, playing,
        string.format("--- 덩어리 %d 시작 (직전 쓰기로부터 %d 프레임) ---",
          groups, frame - lastWriteFrame))
    end
  end
  lastWriteFrame = frame

  if logged < LOG_MAX then
    logged = logged + 1
    -- 시작 시점의 레지스터를 같이 남긴다.  이것이 드리프트 없는 신원이다
    local note = ""
    if s then
      note = string.format("read %s write %s len %s rate %s",
        tostring(s["cdrom.adpcm.readAddress"]), tostring(s["cdrom.adpcm.writeAddress"]),
        tostring(s["cdrom.adpcm.adpcmLength"]), tostring(s["cdrom.adpcm.playbackRate"]))
    end
    row("write", address, value, pc, bank, playing, note)
  end
end, emu.callbackType.write, IO_LO, IO_HI, emu.cpuType.pce, mem)

emu.addEventCallback(function()
  frame = frame + 1
  emu.drawString(4, 4, string.format("ADPCM 포트 쓰기 %d · 덩어리 %d", writes, groups),
    0xFFFFFF, 0x80000000, 1)
  emu.drawString(4, 14, (writes == 0)
    and "★ 아직 0 -- 음성이 나오는 장면까지 진행하세요"
    or "수집 중.  두 대사가 다 나오면 정지",
    (writes == 0) and 0xFF6060 or 0x80FF80, 0x80000000, 1)
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  local pcs = {}
  for pc, n in pairs(pcTally) do pcs[#pcs + 1] = { pc, n } end
  table.sort(pcs, function(a, b) return a[2] > b[2] end)
  file:write("\n-- 쓰는 PC 별 집계 (많은 순).  여기 위쪽이 재생 진입 후보다 --\n")
  file:write("pc\tcount\n")
  for i = 1, math.min(#pcs, 20) do
    file:write(string.format("%04X\t%d\n", pcs[i][1], pcs[i][2]))
  end
  local ports = {}
  for port, n in pairs(portTally) do ports[#ports + 1] = { port, n } end
  table.sort(ports, function(a, b) return a[1] < b[1] end)
  file:write("\n-- 포트별 쓰기 횟수 --\nport\tcount\n")
  for _, p in ipairs(ports) do
    file:write(string.format("%04X\t%d\n", p[1], p[2]))
  end
  file:write(string.format("\n-- 총 쓰기 %d · 덩어리 %d · PC 종류 %d --\n",
    writes, groups, #pcs))
  file:close()
end, emu.eventType.scriptEnded)

emu.log("PROBE ADPCM호출지점 0.1.0 -- 재생을 거는 코드의 PC 를 찾는다")
emu.log("  ★ 길리언/미카 대사 장면 직전에서 켜고, 두 대사가 다 나오면 정지")
emu.log("  화면의 '쓰기 N' 이 0 이면 아직 음성이 안 나온 것")
emu.log("  출력: " .. OUT)
