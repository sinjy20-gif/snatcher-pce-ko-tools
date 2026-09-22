-- SUB 0.5.144 -- 자막이 끝난 뒤에도 우리 스프라이트가 남는가
--
-- ★ 순수 관측.  아무것도 안 고친다.  게임 무수정.
--
-- 증상 (소유자, 2026-09-03)
-- ---------------------------------------------------------------------------
-- "자막 종료 후 · 다음 자막 출력 전에 노이즈가 너무 많이 나온다."
-- 스크린샷: 화면 중간(책상 위)에 가로로 늘어선 깨진 블록.  자막 세로자리가
-- '중간' 인 조각이 남긴 잔상으로 보인다.  **0.4.6.70 이전부터 있었다.**
--
-- 무엇을 의심하나
-- ---------------------------------------------------------------------------
-- 자막은 스프라이트다.  VRAM SATB($1000)에 우리 항목이 있고 게임이 매 프레임
-- 그걸 DMA 한다.  헬퍼가 복원 직전에 우리 슬롯을 비우는데(`emit_wipe`),
-- 그 판별 조건이 **컨트롤 블록의 '지금' 값**이다:
--
--     pat_hi AND $07 == pattern_bank    그리고
--     0 <= pat_lo - pattern_first < 38
--
-- 그런데 그 컨트롤 블록은 **음성마다 armer 가 덮어쓴다** (음성마다 VRAM 자리가
-- 다르다 -- 디렉터리 9 B 의 뒤 3 B).  그러니 앞 음성의 스프라이트가 정리되기
-- 전에 다음 음성이 무장되면, 지우는 쪽은 **새 자리 기준으로** 옛 스프라이트를
-- 찾게 되어 조건이 영영 안 맞는다.  -> 그 스프라이트는 화면에 남는다.
--
-- 메모의 "반납만으론 부족 -- 스킵 감지를 같이 넣어야 닫힌다" 와 같은 자리다.
--
-- 무엇을 적나
-- ---------------------------------------------------------------------------
--     프레임마다  state($7FDF) · 우리 스프라이트 수 · 그것들이 가리키는 패턴
--     armer 가 마지막으로 쓴 VRAM 자리 (AC 컨트롤 블록)
--     ★ 남은 스프라이트의 패턴이 **지금 무장된 블록 안인가 밖인가**
--
-- 판정
--     state=0 인데 ours>0 이 오래 간다            -> ★ 잔상 확정
--       그 패턴이 지금 블록 **밖**이다            -> ★★ 위 가설 확정.
--                                                   지우는 조건이 옛 자리를 못 본다
--       그 패턴이 지금 블록 **안**인데도 남는다   -> wipe 가 아예 안 돈 것
--                                                   (복원 경로 자체를 안 탔다)
--     state=0 이면 항상 ours=0                    -> 잔상 아님.  다른 데를 봐야 한다
--
-- 산출물  C:/snatcher/dump/leftover_sprites_0_5_144_<시각>.tsv

local MEM  = emu.memType.pceMemory
local VRAM = emu.memType.pceVideoRam
local AC   = emu.memType.pceArcadeCardRam

local STATE_ADDR = 0x7FDF
local SATB       = 0x1000
local SLOTS      = 64
local GLYPH_PALETTE = 0x0F
local MAX_PATTERNS  = 38          -- MAX_GLYPHS(19) x 2

-- 헬퍼 컨트롤 블록 (AC).  armer 가 음성마다 여기에 쓴다
local CTL       = 0x1F1C00 + 432
local CTL_VRAMLO, CTL_VRAMHI = CTL + 4, CTL + 5
local CTL_PBANK, CTL_PFIRST  = CTL + 6, CTL + 7

local QUIET_FRAMES = 30           -- state=0 이 이만큼 이어지면 '자막 없는 구간'

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/leftover_sprites_0_5_144_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tkind\tstate\tours\tquiet\tpat_bank\tpat_first\tpatterns\tinside\toutside\tnote\n')

local function say(m) emu.log(m); print(m) end
local function rd(a)  local ok,v = pcall(emu.read, a, MEM);  return (ok and type(v)=='number') and v or -1 end
local function rac(a) local ok,v = pcall(emu.read, a, AC);   return (ok and type(v)=='number') and v or -1 end
local function rb(a)  local ok,v = pcall(emu.read, a, VRAM); return (ok and type(v)=='number') and v or 0 end
local function rw(word) local at = word*2; return rb(at) | (rb(at+1) << 8) end

-- 지금 무장된 블록
local function armed()
  return rac(CTL_PBANK), rac(CTL_PFIRST), rac(CTL_VRAMHI)
end

-- 우리 스프라이트 = 패턴 0 아님 + 팔레트 $F
local function scan()
  local pats, slots = {}, {}
  for i = 0, SLOTS-1 do
    local base = SATB + i*4
    local pat  = rw(base + 2)
    local attr = rw(base + 3)
    if pat ~= 0 and (attr & 0x0F) == GLYPH_PALETTE then
      pats[#pats+1]  = pat & 0x07FF
      slots[#slots+1] = i
    end
  end
  return pats, slots
end

-- 패턴이 '지금 무장된 블록' 안인가.  헬퍼의 wipe 조건을 그대로 재현한다
local function inside(pat, bank, first)
  if bank < 0 or first < 0 then return false end
  if ((pat >> 8) & 0x07) ~= bank then return false end
  -- 헬퍼: SEC / SBC first / BCC skip / CMP #38 / BCS skip  -- 자리내림 없음
  local lo = pat & 0xFF
  return lo >= first and (lo - first) < MAX_PATTERNS
end

local function join(t, n)
  n = n or 16
  local p = {}
  for i = 1, math.min(#t, n) do p[#p+1] = string.format('%03X', t[i]) end
  if #t > n then p[#p+1] = '...+'..(#t-n) end
  return table.concat(p, ',')
end

local frame, quiet, lastReport, worst = 0, 0, -999, 0

emu.addEventCallback(function()
  frame = frame + 1
  local state = rd(STATE_ADDR)
  if state == 0 then quiet = quiet + 1 else quiet = 0 end

  local pats = scan()
  local bank, first, vhi = armed()
  local nin, nout = 0, 0
  for _, p in ipairs(pats) do
    if inside(p, bank, first) then nin = nin + 1 else nout = nout + 1 end
  end

  out:write(('%d\tF\t%d\t%d\t%d\t%d\t%d\t%s\t%d\t%d\t\n'):format(
    frame, state, #pats, quiet, bank, first, join(pats), nin, nout))

  -- 자막이 없어야 하는 구간인데 우리 스프라이트가 남아 있다
  if quiet >= QUIET_FRAMES and #pats > 0 then
    if #pats > worst then worst = #pats end
    if frame - lastReport > 120 then
      lastReport = frame
      local verdict = (nout > 0)
        and '★★ 지금 블록 **밖** -- 옛 음성 잔상.  wipe 가 못 찾는다'
        or  '★ 지금 블록 안인데도 남음 -- wipe 가 아예 안 돌았다'
      say(('잔상 f%-7d state=0 %d프레임째  우리 스프라이트 %d 개 (안 %d · 밖 %d)')
            :format(frame, quiet, #pats, nin, nout))
      say(('        지금 무장 bank=%d first=%d vram_hi=$%02X'):format(bank, first, vhi))
      say(('        패턴 %s'):format(join(pats)))
      say('        ' .. verdict)
      out:write(('%d\tLEFTOVER\t%d\t%d\t%d\t%d\t%d\t%s\t%d\t%d\t%s\n'):format(
        frame, state, #pats, quiet, bank, first, join(pats), nin, nout, verdict))
      out:flush()
    end
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:write(('# 최대 잔상 스프라이트 %d 개\n'):format(worst))
  out:close()
end, emu.eventType.scriptEnded)

say('SUB 0.5.144-leftover-sprites armed -- 순수 관측')
say('  ★ 볼 것: state=0 이 30 프레임 넘게 이어지는데 우리 스프라이트가 남는가')
say('    남는다면 그 패턴이 지금 무장된 블록 **밖**인지 안인지가 답을 가른다')
say('  ' .. PATH)
