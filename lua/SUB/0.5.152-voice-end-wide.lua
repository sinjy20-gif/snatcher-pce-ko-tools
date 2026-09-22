-- SUB 0.5.152 -- 음성 끝: 스프라이트 전체 슬롯 + 배경 그림이 실제로 바뀌는가
--
-- ★ 순수 관측.  아무것도 안 고친다.  게임 무수정.
--
-- 0.5.151 의 구멍 둘
-- ---------------------------------------------------------------------------
-- 1) SCAN_SLOTS 를 20 으로 잘랐다.  우리 스프라이트가 0..15 였던 것은 화면 중간
--    관측이고, push 는 `$17=$3F` 예산으로 **게임이 자리를 배정**한다.  게임
--    스프라이트 수에 따라 우리 칸이 20 번 밖으로 밀리면 아예 안 보인다.
-- 2) 배경 그림 데이터가 **실제로 바뀌는지**를 안 쟀다.  헬퍼 복원이 엉뚱한
--    주소로 되돌리면 그림이 직접 깨지는데, 스프라이트만 봐서는 절대 안 보인다.
--
-- 이 판이 재는 것
-- ---------------------------------------------------------------------------
--     SATB 64 슬롯 전부   우리 것 · 그 밖 팔레트15 · 총 스프라이트 수
--     배경 그림 지문      $1100-$2BFF 를 48 지점 표본 (0.5.149 실측 최대 $2BBF)
--     글리프 블록 지문    칸마다 플레인2 첫 워드 (복원이 언제 오는지)
--     state · play($180D bit5) · engine
--
-- 판정
--     배경 지문이 음성 끝에 바뀐다      -> ★ 복원이 엉뚱한 데를 덮는다
--     우리 스프라이트가 살아 있고 dirty -> ★ 복원이 스프라이트보다 먼저 왔다
--     둘 다 아닌데 화면은 깨진다        -> 스프라이트도 그림도 아니다.  팔레트/VDC
--
-- 산출물  C:/snatcher/dump/voice_end_wide_0_5_152_<시각>.tsv

local MEM  = emu.memType.pceMemory
local VRAM = emu.memType.pceVideoRam

local ENGINE  = 0x5B80
local A_COUNT = 0x5CFA        -- ★ 0.4.6.71 기준
local A_VHI   = 0x5C7E
local A_PATLO = 0x5CA1
local A_ATTR  = 0x5CA6
local STATE_ADDR = 0x7FDF
local ADPCM_CTRL = 0x180D
local SATB, SLOTS = 0x1000, 64        -- ★ 64 슬롯 전부
local MAX_PATTERNS = 38
local GLYPHS = 19
local BG_LO, BG_HI, BG_STEP = 0x1100, 0x2C00, 0x40   -- 48 지점

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/voice_end_wide_0_5_152_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tkind\tengine\tstate\tplay\tsprites\tours\tdirty\tbg\tglyph\tcells\tslots\tnote\n')

local function say(m) emu.log(m); print(m) end
local function rd(a) local ok,v = pcall(emu.read, a, MEM);  return (ok and type(v)=='number') and v or -1 end
local function rb(a) local ok,v = pcall(emu.read, a, VRAM); return (ok and type(v)=='number') and v or 0 end
local function rw(word) local at = word*2; return rb(at) | (rb(at+1) << 8) end

local function engineUp()
  return rd(ENGINE) == 0x53 and rd(ENGINE+1) == 0x55 and rd(ENGINE+2) == 0x42
end

local L = { vhi = -1, baseLo = -1, patHi = -1 }

local function bgSig()
  local h = 0
  for a = BG_LO, BG_HI - 1, BG_STEP do
    h = (h * 31 + rw(a)) % 4294967296
  end
  return h
end

local function glyphSig()
  if L.vhi <= 0 then return 0 end
  local base, h = L.vhi << 8, 0
  for c = 0, GLYPHS - 1 do
    h = (h * 31 + rw(base + c*64 + 32)) % 4294967296   -- 플레인2 첫 워드
  end
  return h
end

local function scan()
  local total, cells, slots = 0, {}, {}
  for i = 0, SLOTS - 1 do
    local at  = SATB + i*4
    local pat = rw(at + 2) & 0x07FF
    if pat ~= 0 then
      total = total + 1
      if L.baseLo >= 0 and ((pat >> 8) & 0x07) == L.patHi then
        local d = (pat & 0xFF) - L.baseLo
        if d >= 0 and d < MAX_PATTERNS then
          cells[#cells+1] = d // 2
          slots[#slots+1] = i
        end
      end
    end
  end
  return total, cells, slots
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

local frame, last, pBg, junks, bgchg = 0, nil, nil, 0, 0

emu.addEventCallback(function()
  frame = frame + 1
  local up = engineUp()
  if up then
    local vhi, baseLo, attr = rd(A_VHI), rd(A_PATLO), rd(A_ATTR)
    if vhi > 0 and baseLo >= 0 and attr >= 0 then
      L.vhi, L.baseLo, L.patHi = vhi, baseLo, (attr >> 4) & 0x07
    end
  end

  local total, cells, slots = scan()
  local dirty = dirtyCount(cells)
  local bg, gl = bgSig(), glyphSig()
  local state = rd(STATE_ADDR)
  local ctrl  = rd(ADPCM_CTRL)
  local play  = (ctrl >= 0) and ((ctrl & 0x20) ~= 0 and 1 or 0) or -1

  local k = ('%s|%d|%d|%d|%d|%d|%d|%d'):format(tostring(up), state, play, total,
                                               #cells, dirty, bg, gl)
  if k == last then return end
  last = k

  local kind, note = 'SET', ''
  if #cells > 0 and dirty > 0 then
    junks = junks + 1; kind = 'JUNK'
    note = ('우리 스프라이트 %d 칸 중 %d 칸이 복원된 배경이다'):format(#cells, dirty)
    say(('★JUNK f%-7d engine=%s state=%d play=%d  우리 %d 칸 · 더러운 %d · 슬롯 %s')
          :format(frame, tostring(up), state, play, #cells, dirty, join(slots)))
  end
  if pBg and bg ~= pBg then
    bgchg = bgchg + 1
    if kind == 'SET' then kind = 'BGCHG' end
    note = note .. ' | 배경 그림이 바뀌었다'
    say(('★BG   f%-7d engine=%s state=%d play=%d  배경 지문 변화 (스프라이트 총 %d · 우리 %d)')
          :format(frame, tostring(up), state, play, total, #cells))
  end
  pBg = bg

  out:write(('%d\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%08X\t%08X\t%s\t%s\t%s\n'):format(
    frame, kind, tostring(up), state, play, total, #cells, dirty, bg, gl,
    join(cells), join(slots), note))
  out:flush()
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:write(('# JUNK %d · 배경변화 %d\n'):format(junks, bgchg))
  out:close()
  say(('끝 -- ★JUNK %d · ★BG %d'):format(junks, bgchg))
end, emu.eventType.scriptEnded)

say('SUB 0.5.152-voice-end-wide armed -- 순수 관측')
say('  SATB 64 슬롯 전부 + 배경 그림 지문 + 글리프 지문')
say('  볼 것: 음성 끝에 ★JUNK 인가 ★BG 인가 (둘 다 아니면 팔레트/VDC 를 봐야 한다)')
say('  ' .. PATH)
