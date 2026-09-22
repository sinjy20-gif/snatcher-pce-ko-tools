-- PROBE 부팅 적재 0.1.0 -- 부팅에 CD 를 얼마나 읽는지 **실측**한다
--
-- 왜
-- ---------------------------------------------------------------------------
-- "부팅 로딩이 2.85초" 는 계산값이었다.  번역 데이터 428 KB 를 1배속 150 KB/s 로
-- 나눈 것뿐이고, 다음이 전부 빠져 있다:
--
--     디렉터리 64 KB + 상태 + 템플릿      AC 맵 $00000-$16000 = 88 KB
--     섹터 오버헤드                       2048/2352 -- 실효 약 130 KB/s
--     시크                                팩이 흩어져 있으면 팩마다 한 번
--     게임 자신의 부팅 적재                우리 데이터와 무관하게 원래 있는 것
--
-- 그래서 체감이 더 길다.  추측을 늘리지 말고 **섹터 수와 프레임을 직접 센다.**
--
-- 이 값이 필요한 진짜 이유는 before/after 다.  부팅 적재를 all -> resident 로
-- 바꾼 뒤 같은 프로브를 돌리면, 좋아졌는지가 느낌이 아니라 숫자로 나온다.
--
-- 어디서 잡나
-- ---------------------------------------------------------------------------
-- PROBE_CD_READS 0.1.1 이 확인해 둔 규약을 그대로 쓴다.
--
--     $EC05  CD_READ 본체
--     $EC13    JSR $F104     상대 섹터 + CD_BASE
--     $F123    $F104 의 RTS  <- ★ 여기서 $FC/$FD/$FE 가 절대 LBA
--     $F8                    섹터 수
--
-- $F123 에서 읽으면 변환이 끝나 있어 base 를 따로 몰라도 된다.
--
-- 읽는 법
-- ---------------------------------------------------------------------------
-- 파워사이클하고 타이틀 지나 첫 대사까지만 가면 된다.  그 뒤로는 안 봐도 된다.
-- 로그창에 500 프레임마다 누계가 찍히고, Stop 하면 TSV 가 남는다.
--
--     섹터 1개 = 2,048 B.  1배속 실효 약 130 KB/s = 초당 약 65 섹터
--
--   Script -> Settings -> Restrictions -> Allow I/O and OS

local mem = emu.memType.pceMemory

local stamp = "session"
if os ~= nil and os.date ~= nil then stamp = os.date("%Y%m%d_%H%M%S") end
local OUT = "C:\\snatcher\\dump\\probe_boot_load_" .. stamp .. ".tsv"

local frame, reads, sectors = 0, 0, 0
local rows = {}
local firstTextFrame = nil
local lastLogged = 0

local function byte(a) return emu.read(a, mem) or 0 end

-- $F104 의 RTS.  여기서 $FC/$FD/$FE 가 절대 LBA 다
emu.addMemoryCallback(function()
  local lba = byte(0x20FC) * 65536 + byte(0x20FD) * 256 + byte(0x20FE)
  local count = byte(0x20F8)
  if count == 0 then count = 256 end
  reads = reads + 1
  sectors = sectors + count
  rows[#rows + 1] = string.format("%d\t%06X\t%d\t%d\t%d", frame, lba, count, reads, sectors)
end, emu.callbackType.exec, 0xF123, 0xF123, emu.cpuType.pce, mem)

-- 첫 대사가 렌더러에 올라온 순간.  "부팅 끝" 의 기준점으로 쓴다
emu.addMemoryCallback(function()
  if firstTextFrame == nil then
    firstTextFrame = frame
    emu.log(string.format(
      "첫 대사까지 %d 프레임 (%.1f초) · CD 읽기 %d회 %d섹터 (%.0f KB)",
      frame, frame / 60, reads, sectors, sectors * 2048 / 1024))
  end
end, emu.callbackType.exec, 0x5E40, 0x5E40, emu.cpuType.pce, mem)

emu.addEventCallback(function()
  frame = frame + 1
  if frame - lastLogged >= 500 then
    lastLogged = frame
    emu.log(string.format("%5.1f초  누계 %d회 %d섹터 (%.0f KB)",
      frame / 60, reads, sectors, sectors * 2048 / 1024))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  local file = io.open(OUT, "w")
  if file ~= nil then
    file:write("frame\tlba\tsectors\tread_no\tcum_sectors\n")
    for _, r in ipairs(rows) do file:write(r .. "\n") end
    file:close()
  end
  emu.log(string.format(
    "부팅 적재 실측: %d 프레임 동안 %d회 %d섹터 (%.0f KB).  첫 대사 %s",
    frame, reads, sectors, sectors * 2048 / 1024,
    firstTextFrame and string.format("%d 프레임 (%.1f초)", firstTextFrame, firstTextFrame / 60) or "없음"))
  emu.log("  -> " .. OUT)
end, emu.eventType.scriptEnded)

emu.log("PROBE 부팅 적재 0.1.0 -- 파워사이클하고 첫 대사까지만 가면 된다")
emu.log("  -> " .. OUT)
