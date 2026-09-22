-- SUB 0.4.64-fixedbase -- allocator 를 빼고 **키별 고정 base** 로 박는다
--
-- ── 왜 ────────────────────────────────────────────────────────────────────
--
--     SNATCHER_ALLOCATOR_CDDA_2026-08-28 §3-2
--     "allocator 가 고를 때는 비어 있었고, 그 뒤에 게임이 가져갔다.
--      allocator 는 미래를 모른다."
--
-- 초상화는 자막과 **같은 순간**에 올라온다.  t0 의 정보로 t0 에 정하면 직후에
-- 뺏긴다.  오프라인 측정은 [t0,t1] 구간 전체를 보므로 그 문제가 없다.
--
-- `lua/SUB/VRAM-key-map.lua` 가 음성마다 "그 음성이 나는 동안 한 번도 안 쓰인
-- 자리" 를 재고, `tools/build_vram_key_bases.py` 가 키마다 base 하나를 골라
-- 표로 만든다.  이 파일은 그 표를 조회하기만 한다.
--
-- ── 이 판이 없애는 것 ────────────────────────────────────────────────────
--
--     choose()              미래를 모르는 추측
--     snapshot / restore    되돌릴 일이 없다 -> §8-1 "복원이 장면 전환을 덮는다" 소멸
--     침범 경쟁             고를 때 이미 그 음성 내내 안 쓰인다는 게 보장돼 있다
--     defer / GRACE / 지문   복원이 없으니 전부 불필요
--     프레임당 64슬롯 스캔   FPS 문제도 같이 사라진다
--
-- ── 측정 결과 (2026-08-29 · 정커 본부 구간 · 192키) ──────────────────────
--
--     BAT/SATB 본체를 빼지 않으면   191/192 키가 배경을 뭉갤 base 를 고른다
--     빼면                          192/192 키가 그래도 자리를 찾는다
--     서로 다른 base                5개 · 최소 여유 144 word
--
-- ⚠ 이 표는 **정커 본부까지만** 측정한 것이다.  그 밖의 장면에서는 키가 표에
--   없어 SKIP 이 뜬다.  전 구간을 재기 전에는 출하 해법이 아니다.
--
-- ── 쓰는 법 ──────────────────────────────────────────────────────────────
--
--   1  python tools/build_vram_key_bases.py      (표를 만든다)
--   2  Power Cycle
--   3  이 파일 하나만 로드
--
-- 화면 우상단 카운터: 고정 N / 미등록 M
--   고정   표에서 자리를 찾아 박은 횟수
--   미등록 키가 표에 없어 건너뛴 횟수 -- 측정 안 한 장면이라는 뜻이다

local MEM = emu.memType.pceMemory
local AC  = emu.memType.pceArcadeCardRam
local CPU = emu.cpuType.pce

local ENGINE   = 0x5B80
local ENTRY    = ENGINE + 3
local READY    = ENGINE + 343
local SELECTOR = ENGINE + 345
local STAGE    = ENGINE + 503
local COUNT_OK = ENGINE + 118
local RECORD_Y = ENGINE + 440 + 3

-- allocator 가 쓰던 것과 같은 피연산자 자리다 (0.3.42-wide patchRenderer).
local VRAM_LO, VRAM_HI, PAT_LO, ATTR = 144, 146, 255, 260

local PACK_AT, ENGINE_AT, AC_PACK = 0x1C0000, 0x1F1F00, 0x1C0000
local PACK_PATH   = 'C:/snatcher/build/cutscene_subs/subtitle_pack.bin'
local ENGINE_PATH = 'C:/snatcher/build/cutscene_subs/engine_ac_lua_frame_mini.bin'
local BASES_PATH  = 'C:/snatcher/build/cutscene_subs/vram_key_bases.lua'
local MINI_COUNT  = rawget(_G, 'SUB_RUNTIME_MINI_COUNT') or 5

local function readFile(path)
  local f = assert(io.open(path, 'rb'), 'cannot open ' .. path)
  local d = f:read('*a'); f:close(); return d
end

local function u32(s, at)
  return s:byte(at + 1) | (s:byte(at + 2) << 8) |
         (s:byte(at + 3) << 16) | (s:byte(at + 4) << 24)
end

local pack   = readFile(PACK_PATH)
local engine = readFile(ENGINE_PATH)
local BASES  = assert(dofile(BASES_PATH), 'base 표를 못 읽었다: ' .. BASES_PATH)

local baseCount = 0
for _ in pairs(BASES) do baseCount = baseCount + 1 end
assert(baseCount > 0, 'base 표가 비었다.  build_vram_key_bases.py 를 먼저 돌린다')

-- ── 1. 가드: 팩 파일과 엔진 파일이 짝인가 ──────────────────────────────────
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
  emu.log('SUB 0.4.64 ✗✗✗ 팩과 엔진이 짝이 아니다 -- 돌리면 화면이 무너진다')
  for _, line in ipairs(bad) do emu.log('    ' .. line) end
  emu.log('    python tools/build_subtitle_engine_ac_lua_frame_mini.py 를 돌리고')
  emu.log('    Power Cycle 후 다시 로드할 것')
  error('SUB 0.4.64: pack/engine mismatch')
end

-- ── 2. 자막 스택 ───────────────────────────────────────────────────────────
SUB_VOICE_KEY_VERSION = '0.4.64'
SUB_VOICE_ENGINE_PATH = ENGINE_PATH
SUB_VOICE_ENGINE_BYTES = #engine
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

emu.addMemoryCallback(function()
  if (emu.read(RECORD_Y, MEM) or 0) ~= 122 then
    emu.write(RECORD_Y, 122, MEM)
  end
end, emu.callbackType.exec, COUNT_OK, COUNT_OK, CPU, MEM)

-- ── 3. AC RAM 을 파일과 맞춘다 ─────────────────────────────────────────────
local PACK_FIELDS = { 8, 10, 14, 16, 20, 22, 26, 30 }
local function acU32(at)
  local v = 0
  for i = 0, 3 do v = v | ((emu.read(PACK_AT + at + i, AC) or 0) << (8 * i)) end
  return v
end
local packDiff = 0
for _, at in ipairs(PACK_FIELDS) do
  if u32(pack, at) ~= acU32(at) then packDiff = packDiff + 1 end
end
if packDiff > 0 then
  for i = 1, #pack do emu.write(PACK_AT + i - 1, pack:byte(i), AC) end
end
for i = 1, #engine do emu.write(ENGINE_AT + i - 1, engine:byte(i), AC) end

-- ── 4. stage 재무장 ────────────────────────────────────────────────────────
local ROUTINE
do
  local at = engine:find('\x60', 504, true)
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

local rearmed = 0
emu.addMemoryCallback(function()
  if (emu.read(READY, MEM) or 0xFF) ~= 0 then return end
  if not matches(ENGINE, MAGIC) or not matches(ENGINE + 8, JSR) then return end
  if matches(STAGE, ROUTINE) then return end
  for i = 1, #ROUTINE do emu.write(STAGE + i - 1, ROUTINE:byte(i), MEM) end
  rearmed = rearmed + 1
end, emu.callbackType.exec, ENTRY, ENTRY, CPU, MEM)

-- ── 5. ★ 키별 고정 base ────────────────────────────────────────────────────
-- 키는 selector 앞 6 B 다.  Lua 가 거기 써 둔 것이고, 엔진이 색인을 맞출 때
-- 쓰는 바로 그 값이다.  ADPCM 상태를 다시 계산할 필요가 없다.
local function currentKey()
  local t = {}
  for i = 0, 5 do
    t[i + 1] = string.format('%02X', emu.read(SELECTOR + i, MEM) or 0)
  end
  return table.concat(t)
end

local placed, unknown, lastBase = 0, 0, nil
local missing = {}

emu.addMemoryCallback(function()
  local key = currentKey()
  local base = BASES[key]
  if not base then
    if not missing[key] then
      missing[key] = true
      unknown = unknown + 1
      emu.log(string.format('SUB 0.4.64 ▲ 표에 없는 키 %s -- 이 장면은 측정 안 됐다', key))
    end
    return
  end

  -- allocator 의 patchRenderer 와 같은 공식이다.
  --   off 281 = 0x80(앞쪽우선) | 패턴상위<<4 | 팔레트  ($6463 이 AND #$70 / #$8F)
  emu.write(ENGINE + VRAM_LO, base & 0xFF, MEM)
  emu.write(ENGINE + VRAM_HI, base >> 8, MEM)
  emu.write(ENGINE + PAT_LO, (base >> 5) & 0xFF, MEM)
  emu.write(ENGINE + ATTR, 0x80 | (((base >> 13) & 0x07) << 4) | 0x0F, MEM)

  placed = placed + 1
  if base ~= lastBase then
    lastBase = base
    emu.log(string.format('SUB 0.4.64 ★ %s -> 고정 base $%04X', key, base))
  end
end, emu.callbackType.exec, COUNT_OK, COUNT_OK, CPU, MEM)

emu.addEventCallback(function()
  emu.drawString(4, 34, string.format('0.4.64 고정 %d  미등록 %d', placed, unknown),
                 unknown > 0 and 0xFFA000 or 0x60FF60, 0x000000)
end, emu.eventType.endFrame)

emu.log(string.format('SUB 0.4.64-fixedbase armed -- 키 %d개 표 · allocator 없음', baseCount))
emu.log('    표: ' .. BASES_PATH)
emu.log(string.format('    팩 %d B · 엔진 %d B · 짝 확인 완료%s',
                      #pack, #engine, packDiff > 0 and ' · AC 팩 갱신함' or ''))
emu.log('    snapshot/restore 없음 · choose() 없음 · 침범 감시 없음')
emu.log('    ⚠ 표는 정커 본부까지만 측정했다.  다른 장면은 "미등록" 으로 뜬다')
