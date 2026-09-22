-- SUB 0.4.43 -- 0.4.41(stage 재무장) + 팩·엔진 정합성 가드
--
-- 0.4.41 은 다중 조각 정지를 고쳤다.  이 판은 그 위에 **그 수정이 실제로 기기에
-- 올라갔는지** 보장하는 두 개의 가드를 얹는다.  2026-08-28 밤에 같은 함정에 세
-- 번 걸렸기 때문이다.
--
-- ── 가드 1: 팩과 엔진이 짝인가 ─────────────────────────────────────────────
--
-- build_subtitle_engine_ac_lua_frame_mini.py 는 팩 헤더의 오프셋을 **엔진
-- 바이너리에 상수로 박아** 빌드한다:
--
--     glyph_off  = pack[10..13]   ->  glyph_base  = $1C0000 + glyph_off
--     record_off = pack[26..29]   ->  record_base = $1C0000 + record_off
--
-- 그래서 팩만 다시 빌드하고 엔진을 안 뽑으면 엔진이 엉뚱한 자리를 읽는다.
-- 레코드 첫 바이트가 글리프 개수(count)라, 그게 쓰레기가 되면 push 루프가 19 개가
-- 아니라 최대 255 개 스프라이트를 SATB 에 밀어 화면 전체가 무너진다.
-- (실측: 팩 180,818 -> 183,255 B 로 바뀌었을 때 record_base 가 517 B 어긋났다)
--
-- 엔진 이미지에서 그 주소 피연산자가 들어앉는 자리는 아래 네 곳이다.
-- 실측으로 잡았다 -- 팩만 바꿔 두 이미지를 diff 하면 정확히 이 넷만 달라진다.
--
--     off  72 = record_base 하위      off  80 = record_base 중위
--     off 202 = glyph_base  하위      off 209 = glyph_base  중위
--
-- ── 가드 2: 그 엔진이 AC RAM 까지 갔는가 ───────────────────────────────────
--
-- 0.4.31 의 ensureInstalled() 는 오프셋 {0,1,2,50,630} 만 비교한다.  위 네 자리를
-- 하나도 덮지 않는다.  그래서 엔진을 새로 뽑아도 AC RAM 에 옛 이미지가 남아 있으면
-- **검사를 통과해버리고 새 것을 안 올린다.**  파일은 맞는데 기기는 틀린 상태가
-- 조용히 만들어지고, 수정이 실패한 것처럼 보인다.
--
-- 이 판은 로드 시점에 엔진 이미지를 AC 에 무조건 다시 쓴다.  631 B 다.

dofile('C:/snatcher/lua/SUB/0.4.41.lua')

local AC  = emu.memType.pceArcadeCardRam
local MEM = emu.memType.pceMemory

local PACK_AT, ENGINE_AT = 0x1C0000, 0x1F1F00
local AC_PACK = 0x1C0000

local PACK_PATH   = 'C:/snatcher/build/cutscene_subs/subtitle_pack.bin'
local ENGINE_PATH = 'C:/snatcher/build/cutscene_subs/engine_ac_lua_frame_mini.bin'

-- 주소 피연산자가 박히는 자리 (0-based).  엔진 레이아웃이 바뀌면 여기도 바뀐다.
local OPERANDS = {
  { name = 'record_base', header = 26, lo = 72,  mid = 80 },
  { name = 'glyph_base',  header = 10, lo = 202, mid = 209 },
}

local function readFile(path)
  local f = assert(io.open(path, 'rb'), 'cannot open ' .. path)
  local d = f:read('*a'); f:close(); return d
end

local function u32(s, at)   -- at 은 0-based
  return s:byte(at + 1) | (s:byte(at + 2) << 8) |
         (s:byte(at + 3) << 16) | (s:byte(at + 4) << 24)
end

local pack   = readFile(PACK_PATH)
local engine = readFile(ENGINE_PATH)

-- ── 가드 1 ────────────────────────────────────────────────────────────────
local bad = {}
for _, op in ipairs(OPERANDS) do
  local want = AC_PACK + u32(pack, op.header)
  local got  = engine:byte(op.lo + 1) | (engine:byte(op.mid + 1) << 8)
  if got ~= (want & 0xFFFF) then
    bad[#bad + 1] = string.format('%s: 엔진 $..%04X · 팩 $%06X', op.name, got, want)
  end
end

if #bad > 0 then
  emu.log('SUB 0.4.43 ✗✗✗ 팩과 엔진이 짝이 아니다 -- 이 상태로 돌리면 화면이 무너진다')
  for _, line in ipairs(bad) do emu.log('    ' .. line) end
  emu.log(string.format('    팩 %d B (%s)', #pack, PACK_PATH))
  emu.log('    고치는 법:  python tools/build_subtitle_engine_ac_lua_frame_mini.py')
  emu.log('    그리고 Power Cycle 후 이 스크립트를 다시 로드할 것')
  error('SUB 0.4.43: pack/engine mismatch -- 엔진을 다시 빌드하라')
end

-- ── 가드 2 ────────────────────────────────────────────────────────────────
-- ensureInstalled() 의 지문이 못 잡는 자리라, 조건 없이 다시 쓴다.
local stale = 0
for _, op in ipairs(OPERANDS) do
  for _, off in ipairs({ op.lo, op.mid }) do
    if (emu.read(ENGINE_AT + off, AC) or -1) ~= engine:byte(off + 1) then
      stale = stale + 1
    end
  end
end
for i = 1, #engine do
  emu.write(ENGINE_AT + i - 1, engine:byte(i), AC)
end

emu.log(string.format('SUB 0.4.43 armed -- 팩 %d B · 엔진 %d B · 짝 확인 완료', #pack, #engine))
for _, op in ipairs(OPERANDS) do
  emu.log(string.format('    %-12s $%06X  (엔진 off %d/%d)',
                        op.name, AC_PACK + u32(pack, op.header), op.lo, op.mid))
end
if stale > 0 then
  emu.log(string.format('    ★ AC RAM 에 옛 엔진이 있었다 (주소 바이트 %d/4 불일치).  덮어썼다', stale))
else
  emu.log('    AC RAM 엔진은 이미 최신이었다.  그래도 631 B 를 다시 올렸다')
end
