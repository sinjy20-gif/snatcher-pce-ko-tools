-- SUB 0.5.151 -- 음성이 끝나는 순간 스프라이트가 복원된 배경을 그리는가
--
-- ★ 순수 관측.  아무것도 안 고친다.  게임 무수정.
--
-- 0.5.150 이 왜 아무것도 못 봤나
-- ---------------------------------------------------------------------------
-- `engineUp()` 이 false 면 바로 빠져나오게 해놨는데, **음성이 끝나면 엔진이
-- 내려간다.**  하필 봐야 할 순간에 눈을 감고 있었다.
-- (떠 있는 동안은 깨끗했다: dirty 0 · 팔레트 1FF/000 · screen==count 16/16)
--
-- 소유자 증언: "정확하게 자막이 끝나는 타이밍, ADPCM 이 끝나는 타이밍"
--
-- 무엇을 의심하나 -- 헬퍼 주석에 이미 적혀 있다
-- ---------------------------------------------------------------------------
--     "복원은 표시 구간 한복판에서 VRAM 을 덮는다.  그 사이 우리 자막
--      스프라이트가 그 자리를 패턴 소스로 가리키고 있으면, 그 프레임에
--      복원 중인 데이터를 글자로 그린다 -- 대사 자리에 1 프레임짜리 깨진
--      화면이 뜬다 (0.5.9/0.5.10 으로 확정)"
--
-- 그래서 헬퍼는 복원 전에 우리 SATB 슬롯을 먼저 비운다(`emit_wipe`).  그 비우기가
-- 안 먹으면 배경 데이터(4 플레인)가 글자 모양으로 그려져 **알록달록한 블록**이 된다.
--
-- 이 판이 다른 점
-- ---------------------------------------------------------------------------
-- 엔진이 내려가도 **계속 본다.**  엔진이 살아 있을 때 마지막으로 본
-- base/attr/vram_hi 를 걸어두고(latch), 그 값으로 음성이 끝난 뒤까지 훑는다.
--
--     screen   화면에 뜬 우리 스프라이트 수
--     dirty    그 스프라이트가 가리키는 칸의 플레인2·3 이 0 이 아닌 수
--              (우리 글리프는 항상 0 이다 -- 0 이 아니면 복원된 배경이다)
--
-- 판정
--     ★JUNK (screen>0 · dirty>0)  -> ★ 확정.  복원이 스프라이트보다 먼저 왔다
--                                     몇 프레임 지속되는지가 같이 찍힌다
--     screen 이 0 이 된 뒤에 dirty  -> 정상 (아무도 안 가리킨다)
--     끝까지 JUNK 없음             -> 이 경로도 결백.  다른 데를 봐야 한다
--
-- 산출물  C:/snatcher/dump/voice_end_0_5_151_<시각>.tsv

local MEM  = emu.memType.pceMemory
local VRAM = emu.memType.pceVideoRam

local ENGINE  = 0x5B80
local A_COUNT = 0x5CFA        -- ★ 0.4.6.71 기준
local A_VHI   = 0x5C7E
local A_PATLO = 0x5CA1
local A_ATTR  = 0x5CA6
local STATE_ADDR = 0x7FDF
local ADPCM_CTRL = 0x180D
local SATB, SCAN_SLOTS = 0x1000, 20
local MAX_PATTERNS = 38
local GLYPHS = 19

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/voice_end_0_5_151_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tkind\tengine\tstate\tplay\tscreen\tdirty\tcells\txs\tnote\n')

local function say(m) emu.log(m); print(m) end
local function rd(a) local ok,v = pcall(emu.read, a, MEM);  return (ok and type(v)=='number') and v or -1 end
local function rb(a) local ok,v = pcall(emu.read, a, VRAM); return (ok and type(v)=='number') and v or 0 end
local function rw(word) local at = word*2; return rb(at) | (rb(at+1) << 8) end

local function engineUp()
  return rd(ENGINE) == 0x53 and rd(ENGINE+1) == 0x55 and rd(ENGINE+2) == 0x42
end

-- 엔진이 살아 있을 때 본 값을 걸어둔다.  내려간 뒤에도 이 값으로 계속 본다
local L = { vhi = -1, baseLo = -1, patHi = -1 }

local function usedCells()
  local cells, xs = {}, {}
  if L.baseLo < 0 then return cells, xs end
  for i = 0, SCAN_SLOTS-1 do
    local at  = SATB + i*4
    local pat = rw(at + 2) & 0x07FF
    if pat ~= 0 and ((pat >> 8) & 0x07) == L.patHi then
      local d = (pat & 0xFF) - L.baseLo
      if d >= 0 and d < MAX_PATTERNS then
        cells[#cells+1] = d // 2
        xs[#xs+1] = rw(at + 1) & 0x03FF
      end
    end
  end
  return cells, xs
end

local function dirtyCount(cells)
  if L.vhi <= 0 then return 0 end
  local base, seen, n = L.vhi << 8, {}, 0
  for _, c in ipairs(cells) do
    if not seen[c] and c < GLYPHS then
      seen[c] = true
      local at = base + c*64
      for w = 32, 63 do
        if rw(at + w) ~= 0 then n = n + 1 break end
      end
    end
  end
  return n
end

local function join(t)
  local p = {}
  for i = 1, #t do p[#p+1] = tostring(t[i]) end
  return table.concat(p, ',')
end

local frame, last, junks, run = 0, nil, 0, 0

emu.addEventCallback(function()
  frame = frame + 1
  local up = engineUp()
  if up then
    local vhi, baseLo, attr = rd(A_VHI), rd(A_PATLO), rd(A_ATTR)
    if vhi > 0 and baseLo >= 0 and attr >= 0 then
      L.vhi, L.baseLo, L.patHi = vhi, baseLo, (attr >> 4) & 0x07
    end
  end
  if L.baseLo < 0 then return end

  local cells, xs = usedCells()
  local dirty = dirtyCount(cells)
  local state = rd(STATE_ADDR)
  local play  = (rd(ADPCM_CTRL) >= 0) and ((rd(ADPCM_CTRL) & 0x20) ~= 0 and 1 or 0) or -1

  local k = ('%s|%d|%d|%d|%d|%s'):format(tostring(up), state, play, #cells, dirty, join(xs))
  if k == last then return end
  last = k

  local kind, note = 'SET', ''
  if #cells > 0 and dirty > 0 then
    junks = junks + 1; run = run + 1; kind = 'JUNK'
    note = ('스프라이트 %d 칸이 살아 있는데 그중 %d 칸이 복원된 배경이다'):format(#cells, dirty)
    say(('★JUNK f%-7d engine=%s state=%d play=%d  스프라이트 %d 칸 · 더러운 칸 %d')
          :format(frame, tostring(up), state, play, #cells, dirty))
    say(('        칸 %s'):format(join(cells)))
    say(('        x  %s'):format(join(xs)))
  else
    run = 0
    if #cells == 0 and dirty == 0 then kind = 'CLEAN' end
  end
  out:write(('%d\t%s\t%s\t%d\t%d\t%d\t%d\t%s\t%s\t%s\n'):format(
    frame, kind, tostring(up), state, play, #cells, dirty, join(cells), join(xs), note))
  out:flush()
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:write(('# JUNK %d 프레임\n'):format(junks))
  out:close()
  say(('끝 -- ★JUNK %d 프레임'):format(junks))
end, emu.eventType.scriptEnded)

say('SUB 0.5.151-voice-end-junk armed -- 순수 관측')
say('  ★ 엔진이 내려가도 계속 본다.  음성이 끝나는 순간이 목표다')
say('  볼 것: ★JUNK 가 뜨는가 (스프라이트가 살아 있는데 그 자리가 이미 복원됐는가)')
say('  ' .. PATH)
