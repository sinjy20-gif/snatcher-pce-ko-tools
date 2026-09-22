-- SUB 0.4.45 -- 지금까지의 수정을 한 파일로 모은 진입점
--
-- 0.4.38 -> 0.4.41 -> 0.4.43 -> 0.4.44 로 4단 dofile 사슬이 되어 읽기 어려워졌다.
-- 이 파일이 그 전부를 대신한다.  옛 사슬은 오늘 밤 측정 결과를 재현할 수 있게
-- 손대지 않고 그대로 둔다.
--
-- 담고 있는 것
--   0.4.38  Lua 프레임 타이머 · 631 B 독립 list 엔진 · Y=122 보정
--   0.4.41  stage 재무장          -- 다중 조각 정지의 원인을 막는다
--   0.4.43  팩<->엔진 정합성 가드
--   0.4.44  AC RAM 의 팩 강제 갱신
--   0.3.43  잔상 제거 allocator   -- 0.3.42-wide 대신 이것을 쓴다  ★ 이번 변경
--
-- 각 수정의 근거는 해당 파일 머리말에 있다.  여기서는 반복하지 않는다.

local MEM = emu.memType.pceMemory
local AC  = emu.memType.pceArcadeCardRam
local CPU = emu.cpuType.pce

local ENGINE   = 0x5B80
local ENTRY    = ENGINE + 3
local READY    = ENGINE + 343
local STAGE    = ENGINE + 503
local COUNT_OK = ENGINE + 118
local RECORD_Y = ENGINE + 440 + 3

local PACK_AT, ENGINE_AT, AC_PACK = 0x1C0000, 0x1F1F00, 0x1C0000
local PACK_PATH   = 'C:/snatcher/build/cutscene_subs/subtitle_pack.bin'
local ENGINE_PATH = 'C:/snatcher/build/cutscene_subs/engine_ac_lua_frame_mini.bin'
local MINI_COUNT = rawget(_G, 'SUB_RUNTIME_MINI_COUNT') or 5

local function readFile(path)
  local f = assert(io.open(path, 'rb'), 'cannot open ' .. path)
  local d = f:read('*a'); f:close(); return d
end

local function u32(s, at)        -- at 은 0-based
  return s:byte(at + 1) | (s:byte(at + 2) << 8) |
         (s:byte(at + 3) << 16) | (s:byte(at + 4) << 24)
end

local pack   = readFile(PACK_PATH)
local engine = readFile(ENGINE_PATH)

-- ── 1. 가드: 팩 파일과 엔진 파일이 짝인가 ──────────────────────────────────
-- 엔진은 팩 헤더의 오프셋을 상수로 박고 빌드된다.  팩만 다시 빌드하면 엔진이
-- 엉뚱한 자리를 읽고, 레코드의 count 가 쓰레기가 되어 화면이 무너진다.
-- 아무것도 설치하기 전에 여기서 죽는다.
local OPERANDS = {
  { name = 'record_base', header = 26, lo = 72,  mid = 80 },
  { name = 'glyph_base',  header = 10, lo = 202, mid = 209 },
}

local bad = {}
for _, op in ipairs(OPERANDS) do
  local want = AC_PACK + u32(pack, op.header)
  local got  = engine:byte(op.lo + 1) | (engine:byte(op.mid + 1) << 8)
  if got ~= (want & 0xFFFF) then
    bad[#bad + 1] = string.format('%s: 엔진 $..%04X · 팩 $%06X', op.name, got, want)
  end
end
if #bad > 0 then
  emu.log('SUB 0.4.45 ✗✗✗ 팩과 엔진이 짝이 아니다 -- 돌리면 화면이 무너진다')
  for _, line in ipairs(bad) do emu.log('    ' .. line) end
  emu.log(string.format('    팩 %d B · 엔진 %d B', #pack, #engine))
  emu.log('    고치는 법:  python tools/build_subtitle_engine_ac_lua_frame_mini.py')
  emu.log('    그 뒤 Power Cycle 하고 이 스크립트를 다시 로드할 것')
  error('SUB 0.4.45: pack/engine mismatch -- 엔진을 다시 빌드하라')
end

-- ── 2. 자막 스택 ───────────────────────────────────────────────────────────
SUB_VOICE_KEY_VERSION = '0.4.45'
SUB_VOICE_ENGINE_PATH = ENGINE_PATH
SUB_VOICE_ENGINE_BYTES = #engine      -- 631 을 박지 않는다.  파일에서 잰다
SUB_VOICE_SELECTOR = 345
SUB_VOICE_MINI_INDEX = 0x1EF000
SUB_VOICE_MINI_COUNT = MINI_COUNT
SUB_VOICE_LUA_TIMER = true
SUB_VOICE_READY_OFFSET = 343
SUB_VOICE_NO_NEXT_SELECTOR = true
dofile('C:/snatcher/lua/SUB/0.4.31.lua')
SUB_VOICE_KEY_VERSION = nil
SUB_VOICE_ENGINE_PATH = nil
SUB_VOICE_ENGINE_BYTES = nil
SUB_VOICE_SELECTOR = nil
SUB_VOICE_MINI_INDEX = nil
SUB_VOICE_MINI_COUNT = nil
SUB_VOICE_LUA_TIMER = nil
SUB_VOICE_READY_OFFSET = nil
SUB_VOICE_NO_NEXT_SELECTOR = nil

-- record.y 보정.  0.4.38 과 같다.
emu.addMemoryCallback(function()
  if (emu.read(RECORD_Y, MEM) or 0) ~= 122 then
    emu.write(RECORD_Y, 122, MEM)
  end
end, emu.callbackType.exec, COUNT_OK, COUNT_OK, CPU, MEM)

-- ── 3. allocator (잔상 제거판) ─────────────────────────────────────────────
SUB_ALLOCATOR_VERSION = '0.4.45-defer'
SUB_ALLOCATOR_INPLACE_IMAGES = true
SUB_ALLOCATOR_TARGET_END = false
SUB_ALLOCATOR_PATCH_AT_COUNT_OK = true
SUB_ALLOCATOR_REQUIRE_MATCHED = true
SUB_ALLOCATOR_ENGINE = ENGINE
SUB_ALLOCATOR_REBUILD_OFFSET = 17
SUB_ALLOCATOR_COUNT_OK_OFFSET = 118
SUB_ALLOCATOR_VRAM_LO_OFFSET = 144
SUB_ALLOCATOR_VRAM_HI_OFFSET = 146
SUB_ALLOCATOR_PAT_LO_OFFSET = 255
SUB_ALLOCATOR_ATTR_OFFSET = 260
dofile('C:/snatcher/lua/SUB/0.3.43-defer.lua')
SUB_ALLOCATOR_VERSION = nil
SUB_ALLOCATOR_INPLACE_IMAGES = nil
SUB_ALLOCATOR_TARGET_END = nil
SUB_ALLOCATOR_PATCH_AT_COUNT_OK = nil
SUB_ALLOCATOR_REQUIRE_MATCHED = nil
SUB_ALLOCATOR_ENGINE = nil
SUB_ALLOCATOR_REBUILD_OFFSET = nil
SUB_ALLOCATOR_COUNT_OK_OFFSET = nil
SUB_ALLOCATOR_VRAM_LO_OFFSET = nil
SUB_ALLOCATOR_VRAM_HI_OFFSET = nil
SUB_ALLOCATOR_PAT_LO_OFFSET = nil
SUB_ALLOCATOR_ATTR_OFFSET = nil

-- ── 4. 가드: AC RAM 의 팩·엔진을 파일과 맞춘다 ─────────────────────────────
-- 0.4.31 의 ensureInstalled() 는 팩을 버전 바이트로만, 엔진을 오프셋
-- {0,1,2,50,끝} 으로만 본다.  둘 다 세대가 달라도 통과한다.  여기서 확실히 한다.
local PACK_FIELDS = { 8, 10, 14, 16, 20, 22, 26, 30 }
local function acU32(at)
  local v = 0
  for i = 0, 3 do v = v | ((emu.read(PACK_AT + at + i, AC) or 0) << (8 * i)) end
  return v
end

local packDiff = {}
for _, at in ipairs(PACK_FIELDS) do
  if u32(pack, at) ~= acU32(at) then packDiff[#packDiff + 1] = at end
end
if #packDiff > 0 then
  for i = 1, #pack do emu.write(PACK_AT + i - 1, pack:byte(i), AC) end
end
for i = 1, #engine do emu.write(ENGINE_AT + i - 1, engine:byte(i), AC) end

-- ── 5. stage 재무장 ────────────────────────────────────────────────────────
-- entry 는 ready==0 이면 JSR stage 를 한다.  그런데 stage 는 글리프 전송
-- 버퍼이기도 해서 첫 rebuild 가 그 루틴을 글리프 비트맵으로 덮는다.  Lua 는
-- 조각 전환마다 ready=0 을 쓰므로 매번 글리프 픽셀을 코드로 부르게 된다.
local ROUTINE
do
  local at = engine:find('\x60', 504, true)      -- 1-based: stage = 504
  assert(at and at - 504 < 64, 'stage 안에서 RTS 를 못 찾았다')
  ROUTINE = engine:sub(504, at)
end
local MAGIC, JSR = engine:sub(1, 3), engine:sub(9, 11)

local function matches(at, want)
  for i = 1, #want do
    if (emu.read(at + i - 1, MEM) or -1) ~= want:byte(i) then return false end
  end
  return true
end

local rearmed, skipped = 0, 0
emu.addMemoryCallback(function()
  if (emu.read(READY, MEM) or 0xFF) ~= 0 then return end
  if not matches(ENGINE, MAGIC) or not matches(ENGINE + 8, JSR) then
    skipped = skipped + 1
    return
  end
  if matches(STAGE, ROUTINE) then return end
  for i = 1, #ROUTINE do emu.write(STAGE + i - 1, ROUTINE:byte(i), MEM) end
  rearmed = rearmed + 1
  emu.log(string.format('SUB 0.4.45 ★ stage 재무장 #%d · $%04X %d B (JSR 직전)',
                        rearmed, STAGE, #ROUTINE))
end, emu.callbackType.exec, ENTRY, ENTRY, CPU, MEM)

emu.addEventCallback(function()
  emu.drawString(4, 34, string.format('0.4.45 rearm %d%s', rearmed,
                 skipped > 0 and ('  skip ' .. skipped) or ''),
                 0xFFD060, 0x000000)
end, emu.eventType.endFrame)

-- ── 6. 배너 ────────────────────────────────────────────────────────────────
emu.log(string.format('SUB 0.4.45 armed -- 팩 %d B · 엔진 %d B · 짝 확인 완료', #pack, #engine))
for _, op in ipairs(OPERANDS) do
  emu.log(string.format('    %-12s $%06X  (엔진 off %d/%d)',
                        op.name, AC_PACK + u32(pack, op.header), op.lo, op.mid))
end
if #packDiff > 0 then
  emu.log(string.format('    ★ AC 에 다른 세대의 팩이 있었다 (헤더 %d개 불일치).  %d B 를 다시 올렸다',
                        #packDiff, #pack))
else
  emu.log('    AC 의 팩은 파일과 같았다')
end
emu.log(string.format('    엔진 %d B 를 조건 없이 다시 올렸다', #engine))
emu.log('    allocator: KEY 일치 뒤에만 무장 · 전환에서 복원하지 않고 SATB 가 놓아준 뒤 되돌린다')
