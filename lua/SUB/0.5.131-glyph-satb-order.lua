-- SUB 0.5.131 -- 글리프 업로드와 스프라이트 재배치 중 무엇이 먼저인가 (쓰기 0 B)
--
-- 어디까지 왔나
-- ---------------------------------------------------------------------------
-- 0.5.130 으로 **기각된 것**:
--
--     "전환 시 스프라이트를 안 지운다"   -> 기각.  16 -> 9 로 줄고 x 도 재배치된다
--         f266  16 개  x=99,109,...,201,211   pat=816,...,846   조각 1 (16 칸)
--         f385   9 개  x=121,131,...,185,195  pat=816,...,832   조각 2 (9 칸)
--         (팔레트 $F 를 같이 쓰는 게임 스프라이트 4 개 x=32,32,256,256 pat=160 은 뺀 값)
--
--     pat=816 = 0x330 x 32 word = $6600.  스프라이트 i 가 글리프 슬롯 i 를 가리킨다
--
-- 그리고 두 일이 **서로 다른 프레임**에서 일어난다:
--
--     글리프 비트맵 업로드   hits 734~1499 프레임 · $6600 대에 704~1280 word
--     스프라이트 재배치      hits=27 프레임에 SATB 내용이 바뀜
--
-- 어긋나면 한 프레임 동안 조각 2 의 앞 글자가 조각 1 의 자리에 찍히고, 뒤에는
-- 조각 1 의 글자가 남는다.  사진과 맞는다.
--
-- ★ 이 판은 그 **순서**만 잰다.  기구를 세우지 않는다.
--
-- 무엇을 재나 -- 두 사건을 한 판에서
-- ---------------------------------------------------------------------------
--     glyph_w   그 프레임에 $6600 대(우리 글리프 자리)로 간 VDC 쓰기 word 수
--               ★ base 를 control block 에서 안 읽는다 -- 0.5.129 에서 $FFFF·$00BF
--                 잡값이 나왔다.  스프라이트의 pat 값에서 역산한다 (pat x 32)
--     satb_n    VRAM SATB 를 훑어 센 우리 스프라이트 수 (팔레트 $F, 게임 4 개 제외)
--     satb_x    그 x 목록.  줄이 바뀌면 여기서 바로 보인다
--
-- 둘 다 **매 프레임** 찍되, 둘 중 하나라도 변하면 로그에 남긴다.
--
-- 판정
-- ---------------------------------------------------------------------------
--     글리프가 먼저 바뀌고 SATB 가 나중         ★새 글자가 옛 자리에 찍히는 프레임이 생긴다
--                                               -> 사진 1 과 일치.  순서를 바꾸거나 묶어야 한다
--     SATB 가 먼저 바뀌고 글리프가 나중         옛 글자가 새 자리에 찍힌다 (다른 그림)
--     같은 프레임                               순서 문제가 아니다.  다른 것을 봐야 한다
--
-- ⚠ VRAM 의 SATB 만 본다.  VDC 내부 래치 사본은 안 보인다.
--   그래서 "그 프레임에 실제로 그려진 것" 까지는 못 닫는다.  순서까지가 이 판의 몫이다.
--
-- ★ 화면에 아무것도 안 그린다.  게임을 한 바이트도 안 고친다.  개입 없음.
--
--   BIOS  build/patch/0.4.6.68/Syscard3_galmuri_0.4.6.68.pce
--   CUE   build/patch/0.4.6.68/Snatcher CD-ROMantic (Japan) [KO].cue
--   Power Cycle -> 이 파일만 로드
--   ★ ADPCM_003078_6800_0E  조각 1 16 칸 -> 조각 2 9 칸
--
-- 산출물  C:/snatcher/dump/glyph_satb_order_0_5_131_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local VRAM = emu.memType.pceVideoRam

local ENGINE_LO, ENGINE_HI = 0x5B80, 0x5E1F
local STATE_ADDR = 0x7FDF
local SATB = 0x1000
local SLOTS = 64
local GLYPH_PALETTE = 0x0F
local SPR_WORDS = 32                 -- 스프라이트 pattern 한 단위
local REGION_WORDS = 1216

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/glyph_satb_order_0_5_131_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tstate\thits\tglyph_w\tglyph_lo\tglyph_hi\tglyph_first\tglyph_last\t'
       .. 'ours\tsatb_x\tsatb_pat\tevent\n')

local function say(f, ...) emu.log(string.format(f, ...)) end
local function rd(a)
  local ok, v = pcall(emu.read, a, MEM)
  return (ok and type(v) == 'number') and v or -1
end
local function rb(at)
  local ok, v = pcall(emu.read, at, VRAM)
  return (ok and type(v) == 'number') and v or 0
end
local function rw(word) local at = word * 2; return rb(at) | (rb(at + 1) << 8) end

local LINE_KEY
local function scanline()
  local ok, s = pcall(emu.getState)
  if not ok or not s then return -1 end
  if LINE_KEY == nil then
    LINE_KEY = false
    for _, k in ipairs({ 'vdc.scanline', 'scanline', 'vdc.vCounter', 'ppu.scanline' }) do
      if type(s[k]) == 'number' then LINE_KEY = k; break end
    end
  end
  if LINE_KEY == false then return -1 end
  local v = s[LINE_KEY]
  return type(v) == 'number' and math.floor(v) or -1
end

-- ★ 글리프 자리는 스프라이트의 pat 에서 역산한다 (control block 은 못 믿는다)
local glyphBase = -1

local function scanSatb()
  local xs, pats = {}, {}
  for i = 0, SLOTS - 1 do
    local b = SATB + i * 4
    local x    = rw(b + 1) & 0x03FF
    local pat  = rw(b + 2) & 0x07FF
    local attr = rw(b + 3)
    if pat ~= 0 and (attr & 0x0F) == GLYPH_PALETTE then
      -- 게임 상수 4 개 (x=32,32,256,256 · pat=160) 는 뺀다
      if not (pat == 160 and (x == 32 or x == 256)) then
        xs[#xs + 1] = x
        pats[#pats + 1] = pat
      end
    end
  end
  -- 가장 작은 pat 에서 글리프 base 를 역산
  local minPat = nil
  for _, p in ipairs(pats) do if minPat == nil or p < minPat then minPat = p end end
  if minPat then glyphBase = minPat * SPR_WORDS end
  return xs, pats
end

local selReg, mawr, incr, pendLo = 0, 0, 1, 0
local function incrFrom(hi) local s = (hi >> 3) & 0x03
  return (s == 0) and 1 or (s == 1) and 32 or (s == 2) and 64 or 128 end

local hits = 0
local gN, gLo, gHi, gFirst, gLast = 0, -1, -1, -1, -1
local SAMPLE_EVERY = 32

emu.addMemoryCallback(function(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF
  if port == 0 then selReg = value; return end
  if port == 2 then if selReg == 0x00 then pendLo = value end return end
  if selReg == 0x00 then
    mawr = ((value << 8) | pendLo) & 0xFFFF
  elseif selReg == 0x05 then
    incr = incrFrom(value)
  elseif selReg == 0x02 then
    local a = mawr & 0x7FFF
    if glyphBase >= 0 and a >= glyphBase and a < glyphBase + REGION_WORDS then
      gN = gN + 1
      if gLo < 0 or a < gLo then gLo = a end
      if gHi < 0 or a > gHi then gHi = a end
      if gN == 1 or gN % SAMPLE_EVERY == 0 then
        local l = scanline()
        if gFirst < 0 then gFirst = l end
        gLast = l
      end
    end
    mawr = (mawr + incr) & 0xFFFF
  end
end, emu.callbackType.write, 0x0000, 0x0003, CPU, MEM)

emu.addMemoryCallback(function() hits = hits + 1 end,
  emu.callbackType.exec, ENGINE_LO, ENGINE_HI, CPU, MEM)

local function join(t, n)
  local p = {}
  for i = 1, math.min(#t, n or 20) do p[#p + 1] = tostring(t[i]) end
  if #t > (n or 20) then p[#p + 1] = '...+' .. (#t - (n or 20)) end
  return table.concat(p, ',')
end

local frame, lastSatb = 0, nil

emu.addEventCallback(function()
  frame = frame + 1
  local xs, pats = scanSatb()
  local satbKey = #xs .. '|' .. join(xs, 64)
  local satbChanged = (satbKey ~= lastSatb)
  local glyphWrote  = (gN > 0)

  if satbChanged or glyphWrote then
    local ev = (satbChanged and glyphWrote) and '★같은프레임'
               or satbChanged and 'SATB변경' or '글리프업로드'
    out:write(string.format('%d\t%d\t%d\t%d\t%04X\t%04X\t%d\t%d\t%d\t%s\t%s\t%s\n',
      frame, rd(STATE_ADDR), hits, gN,
      gLo < 0 and 0 or gLo, gHi < 0 and 0 or gHi, gFirst, gLast,
      #xs, join(xs), join(pats), ev))
    out:flush()
    say('f%-5d %-12s hits=%-5d 글리프 %d word $%04X-$%04X line %d..%d  스프라이트 %d',
        frame, ev, hits, gN, gLo < 0 and 0 or gLo, gHi < 0 and 0 or gHi,
        gFirst, gLast, #xs)
    if satbChanged then
      say('        x   [%s]', join(xs))
      say('        pat [%s]', join(pats))
    end
    lastSatb = satbKey
  end

  hits = 0
  gN, gLo, gHi, gFirst, gLast = 0, -1, -1, -1, -1
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:close()
  say('0.5.131 끝 -- 글리프 base(역산) $%04X · 저장 %s',
      glyphBase < 0 and 0 or glyphBase, PATH)
  if glyphBase < 0 then
    say('0.5.131 ⚠ 스프라이트에서 글리프 base 를 못 잡았다.  glyph_w 가 전부 0 이면'
        .. ' 그 탓이다.  판정하지 말 것')
  end
end, emu.eventType.scriptEnded)

say('SUB 0.5.131-glyph-satb-order armed -- 순수 관측 · 게임 무수정 · 화면 무개입')
say('  글리프 업로드와 스프라이트 재배치가 같은 프레임인지, 어긋나는지를 본다')
say('  글리프 base 는 control block 이 아니라 스프라이트 pat 에서 역산한다')
say('  덤프 : ' .. PATH)
