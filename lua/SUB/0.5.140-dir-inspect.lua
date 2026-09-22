-- SUB 0.5.140 -- AC 에 실제로 올라온 디렉터리를 전부 적고, 다른 후보도 찾는다
--
-- ★ 순수 관측.  아무것도 안 고친다.  게임 무수정.
--
-- 0.5.139 에서 나온 것
-- ---------------------------------------------------------------------------
--     디렉터리 $1F2800 · 항목 131 개 · LBA 00306B ~ 003DBA
--     빌드된 것은 953 개인데 131 개뿐이고, 전역 최소 002F0A 에서 시작하지도 않는다
--     찾던 003121 도 003123 도 거기 없다
--
-- 즉 **전체 디렉터리가 그 자리에 안 올라와 있다.**  가정이 하나 더 틀렸다.
-- 그러니 이번엔 해석하지 말고 **있는 그대로 적는다.**
--
-- 무엇을 하나
-- ---------------------------------------------------------------------------
--   1) $1F2800 의 항목을 오름차순이 깨진 뒤까지 넉넉히 적는다 (원바이트 9 B 씩)
--   2) AC 전체를 $100 간격으로 훑어 **디렉터리처럼 생긴 모든 자리**를 보고한다
--      (0.5.139 는 첫 후보에서 멈췄다 -- 그게 잘못이었다)
--   3) 우리가 찾는 LBA 셋을 AC 전체에서 바이트로 직접 찾는다
--
-- ★ 어디서 끊겼는지 반드시 남긴다 (인계서 §2-1 규칙)
--
-- 산출물  C:/snatcher/dump/dir_inspect_0_5_140_<시각>.tsv

local BASE    = 0x1F2800
local STRIDE  = 9
local DUMP_N  = 240           -- 오름차순이 깨져도 이만큼은 적는다
local AC_END  = 0x200000
local WANTED  = { 0x003121, 0x003123, 0x003143, 0x003242, 0x003246 }

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/dir_inspect_0_5_140_' .. STAMP .. '.tsv'
local AC = emu.memType.pceArcadeCardRam

local out = io.open(PATH, 'w')
out:write('kind\tslot\taddr\tlba\tptr\tvram\traw\tnote\n')
local function say(m) emu.log(m); print(m) end
-- ★ AC 를 한 번만 통째로 읽어 둔다.  안 그러면 emu.read 를 수천만 번 부른다
local MEMBUF = {}
do
  say('AC 2 MB 를 읽는 중... (한 번만 한다)')
  local ok = pcall(function()
    for a = 0, AC_END - 1 do MEMBUF[a] = emu.read(a, AC) end
  end)
  if not ok then say('⚠ AC 읽기 실패') end
  say('  읽기 끝')
end
local function rd(a) local v = MEMBUF[a]; return v or -1 end
local function u24be(a)
  local b0,b1,b2 = rd(a), rd(a+1), rd(a+2)
  if b0<0 or b1<0 or b2<0 then return -1 end
  return (b0<<16)|(b1<<8)|b2
end
local function u24le(a)
  local b0,b1,b2 = rd(a), rd(a+1), rd(a+2)
  if b0<0 or b1<0 or b2<0 then return -1 end
  return (b2<<16)|(b1<<8)|b0
end

-- 1) 있는 그대로 덤프
say('=== $1F2800 항목 덤프 ===')
local prev, broke = -1, nil
for i = 0, DUMP_N - 1 do
  local at = BASE + i*STRIDE
  local lba, ptr = u24be(at), u24le(at+3)
  local raw = {}
  for j = 0, STRIDE-1 do raw[#raw+1] = ('%02X'):format(rd(at+j) & 0xFF) end
  local note = ''
  if not broke and (lba < 0x001000 or lba > 0xFFFFFF or lba <= prev) then
    broke = i
    note = '★여기서 오름차순이 깨진다'
    say(('  slot %d 에서 깨짐: LBA %06X (직전 %06X)'):format(i, lba, prev))
  end
  out:write(('ENTRY\t%d\t%06X\t%06X\t%06X\t%02X%02X%02X\t%s\t%s\n'):format(
    i, at, lba & 0xFFFFFF, ptr & 0xFFFFFF,
    rd(at+6) & 0xFF, rd(at+7) & 0xFF, rd(at+8) & 0xFF,
    table.concat(raw, ' '), note))
  prev = lba
end
out:flush()
say(('  %d 개 적었다 (오름차순은 %s 에서 깨짐)'):format(DUMP_N, broke and ('slot '..broke) or '안 깨짐'))

-- 2) 디렉터리처럼 생긴 자리를 **전부** 찾는다
say('=== AC 전체에서 디렉터리 후보 찾기 ===')
local function ascRun(base, want)
  local p, n = -1, 0
  for i = 0, want-1 do
    local v = u24be(base + i*STRIDE)
    if v < 0x001000 or v > 0xFFFFFF or v <= p then return n end
    p, n = v, n+1
  end
  return n
end
local found = 0
for a = 0, AC_END - 0x100, 0x100 do
  if ascRun(a, 16) == 16 then
    local n = ascRun(a, 1200)
    found = found + 1
    local first, last = u24be(a), u24be(a + (n-1)*STRIDE)
    say(('  후보 $%06X · 오름차순 %d 개 · %06X ~ %06X'):format(a, n, first, last))
    out:write(('CANDIDATE\t\t%06X\t%06X\t%06X\t\t\t오름차순 %d 개\n'):format(
      a, first, last, n))
  end
end
say(('  후보 %d 개'):format(found))
out:flush()

-- 3) 찾는 LBA 를 AC 전체에서 바이트로 직접 찾는다
say('=== 찾는 LBA 가 AC 어디에 있나 ===')
for _, w in ipairs(WANTED) do
  local b0, b1, b2 = (w>>16)&0xFF, (w>>8)&0xFF, w&0xFF
  local hits, shown = 0, 0
  for a = 0, AC_END - 3 do
    if MEMBUF[a] == b0 and MEMBUF[a+1] == b1 and MEMBUF[a+2] == b2 then
      hits = hits + 1
      if shown < 8 then
        shown = shown + 1
        say(('  %06X 발견 @ $%06X'):format(w, a))
        out:write(('FOUND\t\t%06X\t%06X\t\t\t\t\n'):format(a, w))
      end
    end
  end
  say(('  %06X : %d 곳%s'):format(w, hits, hits > 8 and ' (앞 8 곳만 적음 ★잘림)' or ''))
  out:write(('COUNT\t\t\t%06X\t\t\t\t%d 곳\n'):format(w, hits))
end
out:flush(); out:close()
say('SUB 0.5.140-dir-inspect 끝')
say('  ' .. PATH)
