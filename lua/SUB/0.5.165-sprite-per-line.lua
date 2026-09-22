-- SUB 0.5.165 -- 자막이 스캔라인당 스프라이트 예산을 얼마나 먹는가
--
-- ★ 순수 관측.  아무것도 안 고친다.
--
-- 증상 (소유자, 2026-09-03)
-- ---------------------------------------------------------------------------
-- 스프라이트 뷰어에서는 인물이 온전한데 **실제 화면에서는 허리가 사라진다.**
-- 자막이 떠 있는 줄에서만 그렇다.
--
-- 뷰어는 SAT 내용을 그대로 그리므로 한도가 안 걸린다.  실제 VDC 는 한 스캔라인에
-- 그릴 수 있는 스프라이트 수가 정해져 있고(HuC6270 은 16 개), 넘치면 **뒤쪽
-- 스프라이트를 버린다.**  자막이 그 줄의 예산을 먹으면 인물이 잘린다.
--
-- 무엇을 재나
-- ---------------------------------------------------------------------------
-- SAT 64 슬롯을 읽어 스프라이트마다 (y, 높이) 를 구하고, **스캔라인마다 몇 개가
-- 겹치는지** 센다.  우리 자막 것과 게임 것을 나눠 센다.
--
--     y   = SATB word0 & 0x3FF,  화면줄 = y - 64
--     높이 = attr bit12~13 (CGY) -> 16 / 32 / 64
--     우리 것 = 팔레트 15 이고 패턴이 글리프 블록 안
--
-- 판정
--     자막 줄의 합계가 16 을 넘는다   -> ★ 확정.  넘치는 만큼 게임 것이 잘린다
--     16 이하인데도 잘린다            -> 다른 한도(픽셀 폭)를 봐야 한다
--
-- 산출물  C:/snatcher/dump/sprite_line_0_5_165_<시각>.tsv

local MEM  = emu.memType.pceMemory
local VRAM = emu.memType.pceVideoRam

local SATB, SLOTS = 0x1000, 64
local GLYPH_PALETTE = 0x0F
local MAX_PATTERNS = 38
local LINE_LIMIT = 16                 -- HuC6270 스캔라인당 스프라이트
local A_PATLO, A_ATTR = 0x5CA1, 0x5CA6   -- ★ 0.4.7.0 기준
local ENGINE = 0x5B80

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/sprite_line_0_5_165_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tline\tours\tgame\ttotal\tover\n')

local function say(m) emu.log(m); print(m) end
local function rd(a) local ok,v = pcall(emu.read, a, MEM);  return (ok and type(v)=='number') and v or -1 end
local function rb(a) local ok,v = pcall(emu.read, a, VRAM); return (ok and type(v)=='number') and v or 0 end
local function rw(w) local at = w*2; return rb(at) | (rb(at+1) << 8) end

local function engineUp()
  return rd(ENGINE) == 0x53 and rd(ENGINE+1) == 0x55 and rd(ENGINE+2) == 0x42
end

local frame, worst, reported = 0, 0, 0

emu.addEventCallback(function()
  frame = frame + 1
  if not engineUp() then return end
  local baseLo, attrImm = rd(A_PATLO), rd(A_ATTR)
  if baseLo < 0 or attrImm < 0 then return end
  local patHi = (attrImm >> 4) & 0x07

  -- 스캔라인별 카운트
  local ours, game = {}, {}
  local anyOurs = false
  for i = 0, SLOTS-1 do
    local at   = SATB + i*4
    local y    = rw(at + 0) & 0x03FF
    local pat  = rw(at + 2) & 0x07FF
    local attr = rw(at + 3)
    if pat ~= 0 then
      local cgy = (attr >> 12) & 0x03
      local h   = (cgy == 0) and 16 or ((cgy == 1) and 32 or 64)
      local top = y - 64
      local mine = false
      if (attr & 0x0F) == GLYPH_PALETTE and ((pat >> 8) & 0x07) == patHi then
        local d = (pat & 0xFF) - baseLo
        mine = (d >= 0 and d < MAX_PATTERNS)
      end
      if mine then anyOurs = true end
      for ln = top, top + h - 1 do
        if ln >= 0 and ln < 240 then
          if mine then ours[ln] = (ours[ln] or 0) + 1
          else game[ln] = (game[ln] or 0) + 1 end
        end
      end
    end
  end
  if not anyOurs then return end

  -- 자막이 있는 줄 중 가장 붐비는 곳
  local bl, bo, bg = -1, 0, 0
  for ln, n in pairs(ours) do
    local t = n + (game[ln] or 0)
    if t > bo + bg then bl, bo, bg = ln, n, (game[ln] or 0) end
  end
  if bl < 0 then return end
  local total = bo + bg
  if total > worst then worst = total end
  if frame - reported > 90 then
    reported = frame
    local over = total > LINE_LIMIT
    say(('%s f%-7d 줄%-3d  자막 %2d + 게임 %2d = %2d / %d %s'):format(
      over and '★넘침' or '  여유', frame, bl, bo, bg, total, LINE_LIMIT,
      over and ('  -> 게임 스프라이트 ' .. (total - LINE_LIMIT) .. ' 개가 잘린다') or ''))
    out:write(('%d\t%d\t%d\t%d\t%d\t%s\n'):format(frame, bl, bo, bg, total, tostring(over)))
    out:flush()
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:write(('# 최대 %d / %d\n'):format(worst, LINE_LIMIT))
  out:close()
  say(('끝 -- 자막 줄 최대 스프라이트 %d / %d'):format(worst, LINE_LIMIT))
end, emu.eventType.scriptEnded)

say('SUB 0.5.165-sprite-per-line armed -- 순수 관측')
say('  ★ 볼 것: 자막이 있는 줄의 합계가 16 을 넘는가')
say('  ' .. PATH)
