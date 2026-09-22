-- CONTROL 0.1.1 - structural control probe (관찰 전용)
--
-- 0.1.0 이 알아낸 것
-- ------------------
--   $34B4 에 0D 가 길게 이어지다가 32 로 바뀌는 게 보였다.  옛
--   runtime_text_audit 이 기다리던 (0D, 32) = BR 쌍이 바로 그 값인데,
--   주소는 $360D/$360E 가 아니라 $34B4 였다.  값은 맞고 주소가 틀렸다는
--   쪽에 무게가 실린다.  다만 같은 값이 수백 번 반복되므로 "대사 한 줄에
--   한 번 쓰이는 제어 코드"라는 그림과는 아직 안 맞는다.  0.1.1 은
--   그 반복을 접어서 '값이 바뀐 순간'만 남긴다.
--
--   0.1.0 의 실수 두 가지도 여기서 고쳤다.
--     * 쓰기 콜백마다 emu.log  -> 콘솔이 폭발
--     * 쓰기 콜백마다 getState -> 이 프로젝트가 이미 금지한 패턴
--       (UI 0.1.62: "콜백 안에서 getState() 를 부르지 않는다").
--       pc=0000 만 잔뜩 나온 것도 이 때문이다.
--
-- 이번 판이 답해야 할 것
-- ----------------------
--   대사 한 줄이 끝나고 다음 줄이 시작되기 직전에, 어느 주소가 어떤 값으로
--   바뀌는가.  BUFFER 줄과 BUFFER 줄 사이에 낀 W 줄이 그 답이다.
--
-- 사용법
--   1. Mesen -> Script -> Settings -> Script Window -> Restrictions
--              -> Allow I/O and OS 체크
--   2. 이것만 단독 실행 (runtime_text_audit.lua / MPR 과 같이 켜지 말 것)
--   3. 파워 사이클 -> 여러 줄짜리 대사를 한 박스 끝까지 넘긴다
--   4. 스크립트 정지 후 control_probe.tsv 확인
--
--   콘솔에는 BUFFER 와 요약만 찍는다.  자세한 건 전부 파일로 간다.

local mem = emu.memType.pceMemory
local outputPath = "C:\\snatcher\\dump\\control_probe.tsv"

-- 감시 범위.  $34B4(0.1.0 의 발견)와 $360D/$360E(옛 가설)를 모두 포함한다.
local WATCH_LOW = 0x3400
local WATCH_HIGH = 0x36FF

-- 값이 바뀐 순간만 남긴다.  같은 값 반복은 접어서 개수만 센다.
local lastValue = {}
local runLength = {}

local frame = 0          -- endFrame 콜백이 갱신한다.  콜백 안에서 getState 금지.
local handle = nil
local rowCount = 0
local bufferCount = 0

local function byte(address)
  return emu.read(address, mem) or 0
end

local function word(address)
  return byte(address) + byte(address + 1) * 0x100
end

local function emit(kind, address, value, note)
  if handle == nil then return end
  rowCount = rowCount + 1
  handle:write(string.format("%d\t%s\t%04X\t%02X\t%s\n",
    frame, kind, address or 0, value or 0, note or ""))
  if rowCount % 64 == 0 then handle:flush() end
end

-- 값이 바뀔 때만 기록하고, 직전 값이 몇 번 반복됐는지를 같이 남긴다.
-- 0.1.0 에서 같은 줄이 수백 개 쏟아진 걸 이 한 가지로 잡는다.
local function onWrite(address, value)
  if lastValue[address] == value then
    runLength[address] = (runLength[address] or 1) + 1
    return
  end
  local previous = runLength[address]
  lastValue[address] = value
  runLength[address] = 1
  emit("W", address, value,
    previous == nil and "first" or string.format("prev_run=%d", previous))
end

-- 대사 한 줄이 완성돼 한국어 프리로더로 넘어가는 지점.  줄 경계 표시다.
local function onBufferComplete()
  local pointer = word(0x3471)
  if pointer ~= 0x3619 and pointer ~= 0x349A then return end
  bufferCount = bufferCount + 1
  emit("BUFFER", pointer, 0, string.format(
    "n=%d 34B4=%02X 34B5=%02X 360D=%02X 360E=%02X",
    bufferCount, byte(0x34B4), byte(0x34B5), byte(0x360D), byte(0x360E)))
  if handle ~= nil then handle:flush() end
  emu.log(string.format("CONTROL BUFFER[%d] ptr=%04X 34B4=%02X rows=%d",
    bufferCount, pointer, byte(0x34B4), rowCount))
end

local function onFrameEnd()
  frame = frame + 1
end

handle = io.open(outputPath, "wb")
if handle == nil then
  emu.log("CONTROL 0.1.1: cannot open " .. outputPath .. "  (Allow I/O and OS 확인)")
else
  handle:write("frame\tkind\taddr\tvalue\tnote\n")
  handle:flush()
end

emu.addMemoryCallback(onWrite, emu.callbackType.write,
  WATCH_LOW, WATCH_HIGH, emu.cpuType.pce, mem)
emu.addMemoryCallback(onBufferComplete, emu.callbackType.exec,
  0x5E40, 0x5E40, emu.cpuType.pce, mem)

-- 프레임 카운터는 이벤트로만 갱신한다.  Mesen 빌드에 따라 이름이 다를 수
-- 있으므로 실패해도 계속 굴러가게 둔다 (frame 이 0 으로 남을 뿐이다).
pcall(function()
  emu.addEventCallback(onFrameEnd, emu.eventType.endFrame)
end)

emu.log("CONTROL 0.1.1 loaded -> " .. outputPath)
emu.log(string.format("CONTROL watch=%04X-%04X  (값이 바뀔 때만 기록)",
  WATCH_LOW, WATCH_HIGH))
