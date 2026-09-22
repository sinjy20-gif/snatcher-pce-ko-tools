-- PROBE_ADPCM_STATUS 0.1.1 - 게임이 ADPCM 재생 상태를 스스로 아는가
--
-- 0.1.0 이 왜 에뮬을 세웠나
-- -------------------------
-- read 콜백 안에서 곧바로 emu.getState() 를 불렀다.  ADPCM 창은 전송 폴링 때문에
-- 프레임당 수백 번 읽히므로 getState 도 그만큼 돌았고, 게임이 멈춘 것처럼 느려졌다.
--
-- 고친 방식
--   1) 주소 단위로 먼저 걸러낸다 (테이블 조회 한 번, 아주 싸다)
--   2) 그 프레임에서 처음 보는 주소일 때만 getState 로 PC 를 얻는다
--   3) 그래도 폭주하면 프레임당 상한에서 끊는다
-- 이러면 getState 는 프레임당 최대 16회(창 크기)로 묶인다.
--
-- 왜 레지스터를 직접 안 읽나
-- --------------------------
-- 상태 레지스터는 읽는 행위가 플래그를 지우는 경우가 있다.  Lua 가 읽으면 관측이
-- 게임을 망가뜨릴 수 있으므로, 읽지 않고 **게임이 읽는 것을 엿본다.**
--
-- 판정
-- ----
--   playing 전환 근처에 특정 PC 의 read 가 몰린다  -> 그 PC 가 게임의 재생 판정
--   read 는 많은데 전환과 무관하다                 -> 버퍼 채우기용 폴링일 뿐
--   read 0 건                                      -> 게임은 타이머로 관리한다
--
-- 쓰는 법
--   평소처럼 놀다가 음성 대사 몇 개 지나가면 Stop.  Stop 해야 census 가 남는다.

local cpu = emu.memType.cpu
local OUT = string.format("C:\\snatcher\\dump\\adpcm_status_0_1_1_%s.tsv", os.date("%H%M%S"))

local IO_LO, IO_HI = 0x1800, 0x180F
-- 한 프레임에 PC 를 캐낼 최대 횟수.  창이 16바이트이므로 이보다 더 필요할 일이 없다.
local PC_LOOKUPS_PER_FRAME = 16

local file = assert(io.open(OUT, "w"))
file:write("kind\tframe\taddr\tpc\tplaying\tcount\tnote\n")
file:flush()

local frame       = 0
local wasPlaying  = false
local closed      = false
local totalReads  = 0
local addrCount   = {}   -- 주소별 누적 (콜백 안에서는 이것만 만진다)
local addrSeen    = {}   -- 주소 -> 마지막으로 PC 를 캔 프레임
local pcCensus    = {}   -- "PC:주소" -> 누적
local lookupsLeft = PC_LOOKUPS_PER_FRAME

local function row(kind, addr, pc, playing, count, note)
  if closed then return end
  file:write(string.format("%s\t%d\t%s\t%s\t%s\t%d\t%s\n",
    kind, frame,
    addr and string.format("$%04X", addr) or "-",
    pc and string.format("$%04X", pc) or "-",
    playing and "yes" or "no", count or 0, note or ""))
  file:flush()
end

-- 콜백 본체는 최대한 가볍게.  getState 는 걸러낸 뒤에만 부른다.
emu.addMemoryCallback(function(address)
  totalReads = totalReads + 1
  addrCount[address] = (addrCount[address] or 0) + 1

  if addrSeen[address] == frame then return end     -- 이 프레임에 이미 봤다
  if lookupsLeft <= 0 then return end               -- 폭주 방어
  addrSeen[address] = frame
  lookupsLeft = lookupsLeft - 1

  local ok, s = pcall(emu.getState)
  local pc = (ok and s) and (s["cpu.pc"] or (s.cpu and s.cpu.pc) or 0) or 0
  local key = string.format("%04X:%04X", pc, address)
  pcCensus[key] = (pcCensus[key] or 0) + 1
  row("read", address, pc, wasPlaying, addrCount[address], "")
end, emu.callbackType.read, IO_LO, IO_HI, emu.cpuType.pce, cpu)

emu.addEventCallback(function()
  frame = frame + 1
  lookupsLeft = PC_LOOKUPS_PER_FRAME
  local ok, s = pcall(emu.getState)
  if not ok or s == nil then return end
  local playing = s["cdrom.adpcm.playing"] == true
  if playing ~= wasPlaying then
    wasPlaying = playing
    row("adpcm", nil, nil, playing, totalReads, playing and "재생 시작" or "재생 종료")
    emu.log(string.format("ADPCM %s (f%d, 누적 read %d)",
      playing and "START" or "END", frame, totalReads))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  local keys = {}
  for k in pairs(pcCensus) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return pcCensus[a] > pcCensus[b] end)
  for _, k in ipairs(keys) do
    local pc, addr = k:match("(%x+):(%x+)")
    row("census", tonumber(addr, 16), tonumber(pc, 16), wasPlaying, pcCensus[k], "")
  end
  for addr, n in pairs(addrCount) do
    row("addr", addr, nil, wasPlaying, n, "주소별 총 read")
  end
  row("census", nil, nil, wasPlaying, totalReads, string.format("고유 PC·주소 조합 %d", #keys))
  closed = true
  file:close()
  emu.log(string.format("PROBE_ADPCM_STATUS 0.1.1: read %d회, 고유 조합 %d -> %s",
    totalReads, #keys, OUT))
end, emu.eventType.scriptEnded)

emu.log("PROBE_ADPCM_STATUS 0.1.1 loaded")
emu.log("  0.1.0 은 read 마다 getState 를 불러 에뮬이 멈췄다.  이제 프레임당 16회로 제한")
emu.log("  레지스터를 직접 읽지 않는다 (읽으면 플래그가 지워질 수 있음)")
emu.log("  음성 대사 몇 개 지나가면 Stop -- Stop 해야 census 가 남는다")
emu.log("  출력: " .. OUT)
