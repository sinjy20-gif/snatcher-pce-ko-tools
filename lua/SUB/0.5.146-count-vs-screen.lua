-- SUB 0.5.146 -- 화면의 자막 칸이 렌더러가 의도한 칸보다 많은가
--
-- ★ 순수 관측.  아무것도 안 고친다.  게임 무수정.
--
-- 앞의 두 판이 왜 틀렸나 (둘 다 오탐이었다)
-- ---------------------------------------------------------------------------
-- 0.5.144  "팔레트 15" 만으로 우리 것을 골랐다.  게임 UI 도 15 를 쓴다.
-- 0.5.145  디렉터리 61 블록 중 "먼저 맞는 것" 을 썼다.  그런데 블록 폭이 38 인데
--          간격은 vram_base_hi 차이 x8 = 8~32 라 **서로 겹친다.**  그래서 인덱스가
--          24,26,..,36,14,16,.. 처럼 두 뭉치로 갈렸다 -- 열 자체가 무의미했다.
--
-- 이 판은 추측을 안 한다
-- ---------------------------------------------------------------------------
-- 렌더러가 CPU 에 그대로 들고 있는 값을 읽는다.  기준이 하나뿐이라 겹칠 일이 없다.
--
--     $5B80  "SUB"          엔진이 실제로 올라와 있는지 확인
--     $5CEE  count          이번 조각에 렌더러가 **의도한** 칸 수
--     $5C95  pattern_base_lo  음성별 패턴 base 하위 (armer 가 박는다)
--     $5C9A  pattern_attr     attr>>4 &7 = 패턴 상위 3 비트
--
--     화면의 우리 칸 = SATB 에서 (pat_hi == attr 의 상위) 이고
--                      0 <= (pat_lo - base_lo) & $FF < 38 인 슬롯
--
-- 판정 -- 군더더기 없다
-- ---------------------------------------------------------------------------
--     화면 칸 == count      정상.  조각이 깨끗하게 바뀐다
--     화면 칸 >  count      ★ 잔상 확정.  push 가 줄어든 칸을 안 지운다
--                             넘치는 슬롯 번호 · 인덱스 · x 가 같이 찍힌다
--     화면 칸 <  count      아직 그리는 중이거나 게임이 우리 슬롯을 빼앗았다
--
-- 산출물  C:/snatcher/dump/count_vs_screen_0_5_146_<시각>.tsv

local MEM  = emu.memType.pceMemory
local VRAM = emu.memType.pceVideoRam

local ENGINE   = 0x5B80
local A_COUNT  = 0x5CEE
local A_PATLO  = 0x5C95
local A_ATTR   = 0x5C9A
local STATE_ADDR = 0x7FDF
local SATB, SLOTS = 0x1000, 64
local MAX_PATTERNS = 38

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/count_vs_screen_0_5_146_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tkind\tstate\tcount\tscreen\tbase\tslots\tidx\txs\tnote\n')

local function say(m) emu.log(m); print(m) end
local function rd(a)  local ok,v = pcall(emu.read, a, MEM);  return (ok and type(v)=='number') and v or -1 end
local function rb(a)  local ok,v = pcall(emu.read, a, VRAM); return (ok and type(v)=='number') and v or 0 end
local function rw(word) local at = word*2; return rb(at) | (rb(at+1) << 8) end

-- 엔진이 올라와 있나 ("SUB")
local function engineUp()
  return rd(ENGINE) == 0x53 and rd(ENGINE+1) == 0x55 and rd(ENGINE+2) == 0x42
end

local function scan(baseLo, patHi)
  local slots, idx, xs = {}, {}, {}
  for i = 0, SLOTS-1 do
    local at   = SATB + i*4
    local pat  = rw(at + 2) & 0x07FF
    if pat ~= 0 and ((pat >> 8) & 0x07) == patHi then
      local d = (pat & 0xFF) - baseLo
      if d >= 0 and d < MAX_PATTERNS then
        slots[#slots+1] = i
        idx[#idx+1]     = d
        xs[#xs+1]       = rw(at + 1) & 0x03FF
      end
    end
  end
  return slots, idx, xs
end

local function join(t)
  local p = {}
  for i = 1, #t do p[#p+1] = tostring(t[i]) end
  return table.concat(p, ',')
end

local frame, last, overs = 0, nil, 0

emu.addEventCallback(function()
  frame = frame + 1
  if not engineUp() then return end

  local count  = rd(A_COUNT)
  local baseLo = rd(A_PATLO)
  local attr   = rd(A_ATTR)
  if count < 0 or baseLo < 0 or attr < 0 then return end
  local patHi  = (attr >> 4) & 0x07

  local slots, idx, xs = scan(baseLo, patHi)
  local screen = #slots
  local k = count .. '/' .. screen .. '|' .. join(slots) .. '|' .. join(xs)
  if k == last then return end
  last = k

  local state = rd(STATE_ADDR)
  local note, kind = '', 'SET'
  if screen > count then
    overs = overs + 1
    kind = 'OVER'
    note = ('화면 %d 칸 > 의도 %d 칸 -- 넘치는 슬롯 %d 개'):format(screen, count, screen - count)
    say(('★OVER f%-7d state=%d  의도 %d 칸인데 화면에 %d 칸'):format(frame, state, count, screen))
    say(('        슬롯 %s'):format(join(slots)))
    say(('        인덱스 %s'):format(join(idx)))
    say(('        x      %s'):format(join(xs)))
  elseif screen > 0 then
    say(('자막 f%-7d state=%d  count=%d 화면=%d  base=$%02X/%d  x %s'):format(
      frame, state, count, screen, baseLo, patHi, join(xs)))
  end

  out:write(('%d\t%s\t%d\t%d\t%d\t%02X:%d\t%s\t%s\t%s\t%s\n'):format(
    frame, kind, state, count, screen, baseLo, patHi,
    join(slots), join(idx), join(xs), note))
  out:flush()
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:write(('# OVER %d 건\n'):format(overs))
  out:close()
end, emu.eventType.scriptEnded)

say('SUB 0.5.146-count-vs-screen armed -- 순수 관측')
say('  기준은 렌더러가 CPU 에 들고 있는 값 하나뿐이다 ($5CEE count · $5C95 base · $5C9A attr)')
say('  ★ 볼 것: 화면 칸이 count 보다 많아지는 ★OVER 가 찍히는가')
say('  ' .. PATH)
