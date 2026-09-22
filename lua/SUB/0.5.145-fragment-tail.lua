-- SUB 0.5.145 -- 조각이 바뀔 때 앞 조각의 오른쪽 칸이 남는가
--
-- ★ 순수 관측.  아무것도 안 고친다.  게임 무수정.
--
-- 0.5.144 를 왜 못 믿나
-- ---------------------------------------------------------------------------
-- "패턴 != 0 이고 팔레트 == $F" 만으로 우리 것을 골랐다.  게임 UI 도 팔레트 15 를
-- 쓰므로 구분이 안 된다.  (한때 "f30 은 부팅 직후니 우리 게 아니다" 로 잘랐는데,
-- 소유자는 **세이브에서 UI 입력부터** 이어 돌렸다 -- 그 근거는 무효다.)
--
-- 실측에서 남은 사실:
--
--     0B0,0B2,0B2,0B2,0B0 + 0A0 x4    무장된 음성과 무관하게 고정 · 918 프레임 지속
--     음성별 자리   pattern base = vram_base_hi x 8 = 0x130~0x3D0  (CD-DA 0x3C8)
--     템플릿 기본   PAT_VRAM $1600 >> 5 = 0xB0
--
-- 0B2 가 3 연속인 것은 글자보다 테두리 반복에 가깝다 -- UI 로 보인다.  다만
-- 0xB0 은 우리 템플릿 기본값과 **겹치므로**, imm 패치가 안 먹은 우리 스프라이트일
-- 가능성도 아직 못 지운다.  그래서 이 판은 셋을 **따로** 센다:
--
--     ours    디렉터리(AC $1F2800)에서 읽은 진짜 블록 안
--     tmpl    템플릿 기본 블록 0xB0..0xD5 안        ★ imm 패치가 안 먹은 것?
--     other   팔레트 15 인데 둘 다 아님             게임 UI 일 가능성
--
-- ★ 그리고 보는 순간이 다르다.  0.5.144 는 state=0 구간만 봤는데, 소유자 증상은
--   **자막이 떠 있는 중**(조각 전환)이다.  이 판은 집합이 바뀔 때마다 다 적는다.
--
-- 무엇을 보나 -- 소유자 증상
-- ---------------------------------------------------------------------------
-- "자막 2 조각이 한 음성인데, 새 조각이 뜰 때 앞 조각이 안 지워진다."
--     길리언시드다만이 = 새 조각        임명된 = 앞 조각        둘이 같이 보인다
--
-- 렌더러는 `push` 에서 게임 루틴 $6463 에 **이번 조각 칸 수만** 넘긴다.
--
--     LDA count / STA $16 / LDA #$3F / STA $17 / JSR $6463
--
-- 앞 조각이 14 칸이고 새 조각이 8 칸이면 8 칸만 덮어쓴다.  가운데 정렬이라
-- 남은 6 칸이 새 줄 바깥으로 삐져나온다.  이 판이 그것을 숫자로 잡는다.
--
-- 판정
--     ★TAIL 이 찍힌다   -> 확정.  push 가 줄어든 칸을 안 지운다
--     칸 수가 줄 때 x 도 같이 좁아지고 TAIL 이 없다  -> 이 경로는 결백
--     ★TMPL 이 자막과 같이 움직인다 -> imm 패치가 안 먹은 것.  UI 아님
--     ★TMPL 이 자막과 무관하게 고정 -> UI 확정.  무시하면 된다
--
-- 산출물  C:/snatcher/dump/fragment_tail_0_5_145_<시각>.tsv

local MEM  = emu.memType.pceMemory
local VRAM = emu.memType.pceVideoRam
local AC   = emu.memType.pceArcadeCardRam

local STATE_ADDR = 0x7FDF
local SATB, SLOTS = 0x1000, 64
local GLYPH_PALETTE = 0x0F
local MAX_PATTERNS  = 38            -- MAX_GLYPHS(19) x 2
local AC_DIR, STRIDE = 0x1F2800, 9
local TMPL_BASE = 0x1600 >> 5       -- 0xB0.  렌더러 템플릿의 안 고쳐진 기본값

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/fragment_tail_0_5_145_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tkind\tstate\tcells\tbase\tidx\txs\ttmpl\tother\tnote\n')

local function say(m) emu.log(m); print(m) end
local function rd(a)  local ok,v = pcall(emu.read, a, MEM);  return (ok and type(v)=='number') and v or -1 end
local function rac(a) local ok,v = pcall(emu.read, a, AC);   return (ok and type(v)=='number') and v or -1 end
local function rb(a)  local ok,v = pcall(emu.read, a, VRAM); return (ok and type(v)=='number') and v or 0 end
local function rw(word) local at = word*2; return rb(at) | (rb(at+1) << 8) end

-- ---- 디렉터리에서 실제 쓰이는 패턴 블록을 모은다 -------------------------
local blocks = {}
do
  local seen, n, lo, hi = {}, 0, 9999, -1
  for i = 0, 1300 do
    local e = AC_DIR + i*STRIDE
    local lba = (rac(e) << 16) | (rac(e+1) << 8) | rac(e+2)
    if lba <= 0 or lba == 0xFFFFFF then break end
    local vh = rac(e+6)
    if vh and vh > 0 and not seen[vh] then
      seen[vh] = true
      local b = vh * 8
      blocks[b] = true
      n = n + 1
      if b < lo then lo = b end
      if b > hi then hi = b end
    end
  end
  say(('디렉터리 글리프 블록 %d 종  패턴 0x%03X ~ 0x%03X'):format(n, lo, hi + MAX_PATTERNS - 1))
  say(('템플릿 기본자리는 0x%03X ~ 0x%03X  (겹치면 구분 못 한다)')
        :format(TMPL_BASE, TMPL_BASE + MAX_PATTERNS - 1))
end

local function ours(pat)
  for base in pairs(blocks) do
    if pat >= base and pat < base + MAX_PATTERNS then return base, pat - base end
  end
  return nil
end

local function scan()
  local idx, xs, base, tmpl, other = {}, {}, nil, {}, {}
  for i = 0, SLOTS-1 do
    local at   = SATB + i*4
    local pat  = rw(at + 2)
    local attr = rw(at + 3)
    if pat ~= 0 and (attr & 0x0F) == GLYPH_PALETTE then
      local p = pat & 0x07FF
      local b, k = ours(p)
      if b then
        base = b
        idx[#idx+1] = k
        xs[#xs+1]   = rw(at + 1) & 0x03FF
      elseif p >= TMPL_BASE and p < TMPL_BASE + MAX_PATTERNS then
        tmpl[#tmpl+1] = p - TMPL_BASE
      else
        other[#other+1] = p
      end
    end
  end
  return idx, xs, base, tmpl, other
end

local function join(t)
  local p = {}
  for i = 1, #t do p[#p+1] = tostring(t[i]) end
  return table.concat(p, ',')
end

local frame, last, lastCells, tails = 0, nil, 0, 0

emu.addEventCallback(function()
  frame = frame + 1
  local idx, xs, base, tmpl, other = scan()
  local k = join(idx)..'|'..join(xs)..'|'..join(tmpl)..'|'..join(other)
  if k == last then return end
  last = k
  local state = rd(STATE_ADDR)
  local cells = #idx
  local note = ''

  -- ★ 앞 조각의 꼬리: 칸 수가 줄었는데 옛 인덱스가 아직 있다
  if cells > 0 and lastCells > cells then
    local maxNew = 0
    for _, v in ipairs(idx) do if v > maxNew then maxNew = v end end
    local expect = (cells - 1) * 2
    if maxNew > expect then
      tails = tails + 1
      note = ('TAIL 새 조각 %d 칸이면 인덱스 0..%d 여야 하는데 %d 까지 있다')
               :format(cells, expect, maxNew)
      say(('★TAIL f%-7d state=%d  %d -> %d 칸  인덱스 %s'):format(
        frame, state, lastCells, cells, join(idx)))
      say(('        x %s'):format(join(xs)))
    end
  end

  out:write(('%d\t%s\t%d\t%d\t%s\t%s\t%s\t%s\t%s\t%s\n'):format(
    frame, (note ~= '' and 'TAIL' or 'SET'), state, cells, tostring(base),
    join(idx), join(xs), join(tmpl), join(other), note))
  out:flush()

  if cells > 0 then
    say(('자막 f%-7d state=%d  %d 칸  인덱스 %s  x %s'):format(
      frame, state, cells, join(idx), join(xs)))
    lastCells = cells
  else
    lastCells = 0
  end
  if #tmpl > 0 and cells > 0 then
    say(('        ★TMPL 같이 떠 있음 %d 개  인덱스 %s'):format(#tmpl, join(tmpl)))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:write(('# TAIL %d 건\n'):format(tails))
  out:close()
end, emu.eventType.scriptEnded)

say('SUB 0.5.145-fragment-tail armed -- 순수 관측')
say('  ★ 볼 것: 조각이 바뀌며 칸 수가 줄 때 ★TAIL 이 찍히는가')
say('  ' .. PATH)
