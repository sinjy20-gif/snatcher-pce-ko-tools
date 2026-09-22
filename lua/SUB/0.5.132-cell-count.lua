-- SUB 0.5.132 -- 렌더러가 실제로 몇 칸을 그리는지 $15 에서 직접 읽는다 (쓰기 0 B)
--
-- 무엇이 안 맞나
-- ---------------------------------------------------------------------------
-- 소스 (tools/build_subtitle_engine_ac_record_poc.py):
--
--     count = min(record.cells, 19)      # CMP #20 / BCC count_ok / LDA #19
--     STA count ; STA $15                # $15 = remaining
--     glyph_loop: ... DEC $15 / BNE glyph_loop
--
-- **정확히 칸수만큼만 돈다.**  `+4` 도, 꼬리 지우기도 없다.
--
-- 그런데 0.5.131 관측은:
--
--     f450  글리프 832 word $6600-$693F  ->  다음 프레임 스프라이트 9
--     f631  글리프 704 word $6600-$68BF  ->  다음 프레임 스프라이트 7
--
-- 9 칸짜리 조각(x 델타 10,10,10,4,10,10,10,10 로 팩 레코드와 정확히 일치)인데
-- 832 word 가 나갔다.  글리프 하나가 64 word 라면 13 개분이다.
--
-- ★ 게다가 GLYPH_BYTES = 64 다 ("우리 글리프는 2 플레인만 싣는다").
--   VRAM 자리는 64 word 인데 쓰는 건 32 word 라는 뜻이고, 그러면 쓰기가
--   **띄엄띄엄**이어야 하는데 실측은 $6600-$693F 연속 832 word 였다.
--   즉 내 블록 산수의 전제부터 틀렸을 수 있다.
--
-- ★ 이 판은 추정으로 메우지 않는다.  **렌더러가 쓴 count 를 그대로 읽는다.**
--
-- 어떻게
-- ---------------------------------------------------------------------------
-- 렌더러는 count 를 제로페이지 $15 에 넣고 DEC 로 줄인다 (복원 카운터와 같은 자리).
-- 그래서 $15 에 쓰인 값의 수열이 곧 그 프레임의 동작이다.
--
--     처음 쓰인 값       그 프레임에 그린 칸수
--     그 뒤 단조감소     루프가 그만큼 돌았다
--     19 로 시작         복원(헬퍼)이다 -- 렌더러가 아니다.  구분해서 본다
--
-- 같이 찍는 것: 그 프레임의 VDC 쓰기 word 수와 주소범위.
-- 그러면 **칸수 : word 수** 비가 바로 나온다.
--
-- 읽는 법
-- ---------------------------------------------------------------------------
--     count 9 · word 288  (=9x32)     글리프당 32 word.  띄엄띄엄 쓴다
--     count 9 · word 576  (=9x64)     글리프당 64 word.  연속
--     count 13 · word 832 (=13x64)    레코드가 정말 13 칸이다
--                                     -> 내가 조각을 잘못 짝지은 것
--     count 9 · word 832              칸수와 무관한 무언가가 더 쓴다  ★새 사실
--
-- ⚠ $15 는 헬퍼(복원)와 렌더러가 **공유**한다.  19 로 시작하는 수열은 복원이다.
--   섞어 읽지 말 것.  kind 칸으로 갈라 찍는다.
--
-- ★ 화면에 아무것도 안 그린다.  게임을 한 바이트도 안 고친다.  개입 없음.
--
--   BIOS  build/patch/0.4.6.68/Syscard3_galmuri_0.4.6.68.pce
--   CUE   build/patch/0.4.6.68/Snatcher CD-ROMantic (Japan) [KO].cue
--   Power Cycle -> 이 파일만 로드 -> 0.5.131 과 같은 장면
--
-- 산출물  C:/snatcher/dump/cell_count_0_5_132_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local VRAM = emu.memType.pceVideoRam

local ENGINE_LO, ENGINE_HI = 0x5B80, 0x5E1F
local ZP15 = 0x2015
local STATE_ADDR = 0x7FDF
local SATB = 0x1000
local SLOTS = 64
local GLYPH_PALETTE = 0x0F
local SPR_WORDS = 32
local REGION_WORDS = 1216
local MAX_LOG = 40

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/cell_count_0_5_132_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tkind\tstate\thits\tfirst_count\tzp_writes\t'
       .. 'glyph_w\tglyph_lo\tglyph_hi\tw_per_cell\tours\tsequence\n')

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

local glyphBase = -1
local function scanSatb()
  local n, minPat = 0, nil
  for i = 0, SLOTS - 1 do
    local b = SATB + i * 4
    local x    = rw(b + 1) & 0x03FF
    local pat  = rw(b + 2) & 0x07FF
    local attr = rw(b + 3)
    if pat ~= 0 and (attr & 0x0F) == GLYPH_PALETTE
       and not (pat == 160 and (x == 32 or x == 256)) then
      n = n + 1
      if minPat == nil or pat < minPat then minPat = pat end
    end
  end
  if minPat then glyphBase = minPat * SPR_WORDS end
  return n
end

local selReg, mawr, incr, pendLo = 0, 0, 1, 0
local function incrFrom(hi) local s = (hi >> 3) & 0x03
  return (s == 0) and 1 or (s == 1) and 32 or (s == 2) and 64 or 128 end

local hits, gN, gLo, gHi = 0, 0, -1, -1
local seq, firstCount = {}, -1

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
    end
    mawr = (mawr + incr) & 0xFFFF
  end
end, emu.callbackType.write, 0x0000, 0x0003, CPU, MEM)

emu.addMemoryCallback(function(address, value)
  value = (value or 0) & 0xFF
  if firstCount < 0 then firstCount = value end
  if #seq < MAX_LOG then seq[#seq + 1] = tostring(value) end
end, emu.callbackType.write, ZP15, ZP15, CPU, MEM)

emu.addMemoryCallback(function() hits = hits + 1 end,
  emu.callbackType.exec, ENGINE_LO, ENGINE_HI, CPU, MEM)

local frame = 0

emu.addEventCallback(function()
  frame = frame + 1
  local ours = scanSatb()

  if #seq > 0 or gN > 0 then
    local kind = (firstCount == 19 and #seq > 20) and '복원' or '렌더러'
    local per = (firstCount > 0) and string.format('%.1f', gN / firstCount) or '-'
    out:write(string.format('%d\t%s\t%d\t%d\t%d\t%d\t%d\t%04X\t%04X\t%s\t%d\t%s\n',
      frame, kind, rd(STATE_ADDR), hits, firstCount, #seq,
      gN, gLo < 0 and 0 or gLo, gHi < 0 and 0 or gHi, per, ours,
      table.concat(seq, ' ')))
    out:flush()
    if kind == '렌더러' then
      say('f%-5d 렌더러  count=%-3d  글리프 %d word $%04X-$%04X  word/칸=%s  스프라이트 %d',
          frame, firstCount, gN, gLo < 0 and 0 or gLo, gHi < 0 and 0 or gHi, per, ours)
      say('        $15 수열: %s', table.concat(seq, ' '))
    end
  end

  hits, gN, gLo, gHi = 0, 0, -1, -1
  seq, firstCount = {}, -1
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:close()
  say('0.5.132 끝 -- 글리프 base(역산) $%04X · 저장 %s',
      glyphBase < 0 and 0 or glyphBase, PATH)
  say('0.5.132 ⚠ $15 는 헬퍼(복원)와 렌더러가 공유한다.  19 로 시작하는 수열은 복원이다')
end, emu.eventType.scriptEnded)

say('SUB 0.5.132-cell-count armed -- 순수 관측 · 게임 무수정 · 화면 무개입')
say('  렌더러가 $15 에 넣는 count 를 그대로 읽어, 글리프 word 수와 나란히 놓는다')
say('  칸수 : word 수 비가 나오면 내 블록 산수가 틀렸는지 바로 갈린다')
say('  덤프 : ' .. PATH)
