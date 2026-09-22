-- SUB 0.4.89-stage -- 재무장 엔진용 stage 재무장.  0.4.58 과 같은 일을 한다.
--
-- 0.4.58 은 STAGE = $5D77 과 파일 오프셋 504 를 하드코딩한다.  재무장 엔진은
-- stage 가 +503 -> +525 로 밀려 $5D8D 이므로 그 값을 쓸 수 없다.  여기서는
-- 빌더가 내보낸 표에서 읽는다.
--
-- 하는 일(0.4.58 과 동일)
-- ---------------------------------------------------------------------------
-- 엔진의 stage 영역은 글리프 전송 버퍼이기도 해서, 첫 조각이 끝나면 글리프
-- 비트맵으로 덮인다.  entry 가 그 자리를 JSR 하므로 다음 조각에서 비트맵을
-- 코드로 실행하게 된다.  그래서 조각 전환 직전에 원본 stage 루틴을 다시 쓴다.

dofile('C:/snatcher/lua/SUB/0.4.89-controller.lua')

local info = assert(rawget(_G, 'SUB_REARM_INFO'), '0.4.89-controller 가 먼저 와야 한다')
local off = info.offsets

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local ENGINE = info.engine_lo
local ENTRY = ENGINE + off.entry
local READY = ENGINE + off.ready
local STAGE = ENGINE + off.stage

local function readFile(path)
  local f = assert(io.open(path, 'rb'), 'cannot open ' .. path)
  local data = f:read('*a'); f:close(); return data
end

local engine = readFile(info.path)
assert(#engine == info.engine_bytes,
       string.format('engine size %d, table says %d', #engine, info.engine_bytes))

-- Lua 문자열은 1-based 다.  stage 오프셋 +N 은 문자열 인덱스 N+1 이다.
local stageAt = off.stage + 1
local at = assert(engine:find('\x60', stageAt, true), 'stage RTS not found')
assert(at - stageAt < 64, 'stage RTS is outside expected range')
local routine = engine:sub(stageAt, at)
assert(#routine == info.stage_routine_bytes,
       string.format('stage routine %d B, table says %d B',
                     #routine, info.stage_routine_bytes))

-- 이분용: 진짜 stage 루틴 대신 RTS 한 바이트만 심는다.
-- stage 루틴은 VCE($0402-$0405)에 스프라이트 팔레트 15를 쓰는 31 B다.
-- VCE도 주소 래치 + 자동증가 구조이고 이 루틴엔 인터럽트 보호가 없다.
-- RTS 하나면 entry의 JSR은 그대로 안전하게 돌아오고 팔레트 쓰기만 사라진다.
-- (덮인 글리프 비트맵을 실행하는 문제도 RTS 한 바이트로 똑같이 막힌다.)
if rawget(_G, 'SUB_STAGE_RTS_ONLY') == true then
  routine = '\x60'
  emu.log('SUB 0.4.89-stage ★ RTS 전용 모드 -- VCE 팔레트 초기화를 하지 않는다')
end

local magic, jsr = engine:sub(1, 3), engine:sub(9, 11)

local function matches(address, want)
  for i = 1, #want do
    if (emu.read(address + i - 1, MEM) or -1) ~= want:byte(i) then return false end
  end
  return true
end

local rearmed, skipped = 0, 0
emu.addMemoryCallback(function()
  if (emu.read(READY, MEM) or 0xFF) ~= 0 then return end
  if not matches(ENGINE, magic) or not matches(ENGINE + 8, jsr) then
    skipped = skipped + 1
    return
  end
  if matches(STAGE, routine) then return end
  for i = 1, #routine do emu.write(STAGE + i - 1, routine:byte(i), MEM) end
  rearmed = rearmed + 1
  emu.log(string.format('SUB 0.4.89 ★ STAGE REARM #%d · $%04X %d B',
                        rearmed, STAGE, #routine))
end, emu.callbackType.exec, ENTRY, ENTRY, CPU, MEM)

emu.addEventCallback(function()
  emu.drawString(4, 34,
    string.format('0.4.89 STAGE rearm:%d skip:%d', rearmed, skipped),
    0xFFD060, 0x000000)
end, emu.eventType.endFrame)

emu.log(string.format('SUB 0.4.89-stage armed -- STAGE $%04X %d B · ENTRY $%04X',
                      STAGE, #routine, ENTRY))
