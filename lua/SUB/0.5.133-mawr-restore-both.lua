-- SUB 0.5.133 -- MAWR 을 **양쪽 다** 되돌린다 (복원 + 글리프 업로드)  ★개입판
--
-- ⚠ 개입판이다.  VDC 에 쓴다.  디스크는 안 건드린다.
--
-- 0.5.126 이 왜 0 점이었나
-- ---------------------------------------------------------------------------
-- 0.5.126 은 `$15` 가 **19 에서 시작해** 0 이 되는 순간만 잡았다.  그건 헬퍼의
-- 복원(19 청크)뿐이다.  렌더러의 글리프 루프는 `count = min(cells,19)` 에서
-- 시작하므로 8·11·14 같은 값이고, **전혀 안 잡혔다.**
--
-- 0.5.132 실측:
--
--     f966   count=11  $15: 11 10 9 ... 1 0   글리프 960 word  -> 다음 프레임 스프라이트 11
--     f1055  count= 8  $15:  8  7 6 ... 1 0   글리프 768 word  -> 다음 프레임 스프라이트  8
--
-- 그리고 word 수가 정확히 갈라진다:
--
--     960 = 11x64 + 256      768 = 8x64 + 256      832 = 9x64 + 256
--     704 =  7x64 + 256     1152 = 14x64 + 256    1216 = 16x64 + 192 (구간끝 잘림)
--
-- ★ 우리 글리프 = 칸수 x 64.  거기에 **고정 256 word** 가 더 붙는다.
--   256 word = SATB 한 판(64 슬롯 x 4 word).  복원 프레임에서 본 그 숫자다.
--
-- 즉 글리프 업로드도 MAWR 을 가져가고 안 돌려주며, 그 프레임 게임의 SATB 갱신이
-- 우리 VRAM 으로 떨어진다.  그래서 스프라이트 표가 그 프레임에 안 바뀌고,
-- 새 글리프는 이미 올라간 채로 이전 조각의 스프라이트가 한 프레임 더 보인다.
--
--     ★ "글리프 N / 스프라이트 N+1" 이라는 한 프레임 어긋남 자체가 MAWR 탈취의
--       **결과**다.  원인과 증상을 따로 세고 있었다.
--
-- 이 판이 하는 일
-- ---------------------------------------------------------------------------
-- `$15` 가 **어떤 값에서든** 0 까지 내려오는 순간을 잡아 MAWR 을 $1000 으로
-- 되돌린다.  복원(19)과 글리프 루프(8·11·14…)를 같은 훅으로 덮는다.
--
--     내림 수열 감지    v>=2 로 시작해 v-1, v-2, ... 로 이어지다 0 에 닿으면 발동
--     ★ $15 는 게임/다른 코드도 쓴다 (32, 53 같은 값이 계속 보인다).
--       그래서 "내림 수열" 이라는 모양으로만 발동한다.  단발 쓰기에는 안 걸린다
--
-- 판정 -- 숫자와 화면 둘 다
-- ---------------------------------------------------------------------------
--     글리프 프레임의 우리자리 word 가 칸수x64 로 떨어진다   ★SATB 가 제자리로 갔다
--     SATB($1000-$10FF) 쓰기가 256 으로 돌아온다              같은 말
--     스프라이트가 글리프와 **같은 프레임**에 바뀐다          ★한 프레임 어긋남 해소
--     화면의 뒤섞임이 사라진다                                증상 1 해결
--
--     ⚠ 숫자가 다 맞는데 화면이 그대로면, 사슬은 맞되 증상 1 의 원인은 또 다른 것이다.
--       그때는 여기서 닫지 말고 그대로 적을 것.
--
-- 끄고 켜기
--     SUB_MAWR_FIX = false  -> 개입 없이 측정만 (대조군)
--
--   BIOS  build/patch/0.4.6.68/Syscard3_galmuri_0.4.6.68.pce
--   CUE   build/patch/0.4.6.68/Snatcher CD-ROMantic (Japan) [KO].cue
--   Power Cycle -> 이 파일만 로드 -> 조각이 여러 개인 대사를 끝까지
--   ★ 조각이 바뀌는 순간을 눈으로 볼 것
--
-- 산출물  C:/snatcher/dump/mawr_both_0_5_133_<시각>.tsv

local ENABLE = rawget(_G, 'SUB_MAWR_FIX')
if ENABLE == nil then ENABLE = true end

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local VRAM = emu.memType.pceVideoRam

local ENGINE_LO, ENGINE_HI = 0x5B80, 0x5E1F
local ZP15 = 0x2015
local SATB_LO, SATB_HI = 0x1000, 0x10FF
local SLOTS, GLYPH_PALETTE, SPR_WORDS = 64, 0x0F, 32
local REGION_WORDS = 1216
local WANT_MAWR = 0x1000
local MIN_RUN = 3

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/mawr_both_0_5_133_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tenabled\tcount\tfires\tglyph_w\tglyph_lo\tglyph_hi\t'
       .. 'expect\tsatb_w\tours\tverdict\n')

local function say(f, ...) emu.log(string.format(f, ...)) end
local function rb(at)
  local ok, v = pcall(emu.read, at, VRAM)
  return (ok and type(v) == 'number') and v or 0
end
local function rw(word) local at = word * 2; return rb(at) | (rb(at + 1) << 8) end

local muted = false
local function wr(a, v) pcall(emu.write, a, v, MEM) end

local selReg, mawr, incr, pendLo = 0, 0, 1, 0
local function incrFrom(hi) local s = (hi >> 3) & 0x03
  return (s == 0) and 1 or (s == 1) and 32 or (s == 2) and 64 or 128 end

local function restoreMawr()
  muted = true
  wr(0x0000, 0x00)
  wr(0x0002, WANT_MAWR & 0xFF)
  wr(0x0003, (WANT_MAWR >> 8) & 0xFF)
  wr(0x0000, selReg)             -- 원래 선택으로 되돌린다 (보통 $02)
  muted = false
  mawr = WANT_MAWR
end

local glyphBase = -1
local function scanSatb()
  local n, minPat = 0, nil
  for i = 0, SLOTS - 1 do
    local b = SATB_LO + i * 4
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

local gN, gLo, gHi, satbN = 0, -1, -1, 0
local runStart, runPrev, fires, lastCount = -1, -1, 0, -1

emu.addMemoryCallback(function(address, value)
  if muted then return end
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
    if a >= SATB_LO and a <= SATB_HI then
      satbN = satbN + 1
    elseif glyphBase >= 0 and a >= glyphBase and a < glyphBase + REGION_WORDS then
      gN = gN + 1
      if gLo < 0 or a < gLo then gLo = a end
      if gHi < 0 or a > gHi then gHi = a end
    end
    mawr = (mawr + incr) & 0xFFFF
  end
end, emu.callbackType.write, 0x0000, 0x0003, CPU, MEM)

-- ★ 내림 수열 감지.  $15 는 다른 코드도 쓰므로 "모양" 으로만 발동한다
emu.addMemoryCallback(function(address, value)
  if muted then return end
  value = (value or 0) & 0xFF
  if runPrev >= 0 and value == runPrev - 1 then
    runPrev = value
    if value == 0 and runStart >= MIN_RUN then
      fires = fires + 1
      lastCount = runStart
      if ENABLE then restoreMawr() end
      runStart, runPrev = -1, -1
    end
  elseif value >= MIN_RUN then
    runStart, runPrev = value, value       -- 새 내림 수열 시작 후보
  else
    runStart, runPrev = -1, -1
  end
end, emu.callbackType.write, ZP15, ZP15, CPU, MEM)

local frame = 0

emu.addEventCallback(function()
  frame = frame + 1
  local ours = scanSatb()

  if fires > 0 or gN > 0 then
    local expect = (lastCount > 0) and (lastCount * 64) or -1
    local verdict
    if expect < 0 then verdict = '-'
    elseif gN == expect then verdict = '★제자리(칸수x64)'
    elseif gN == expect + 256 then verdict = 'SATB 가 우리자리로'
    else verdict = string.format('예상 %d / 실측 %d', expect, gN) end

    out:write(string.format('%d\t%s\t%d\t%d\t%d\t%04X\t%04X\t%d\t%d\t%d\t%s\n',
      frame, tostring(ENABLE), lastCount, fires, gN,
      gLo < 0 and 0 or gLo, gHi < 0 and 0 or gHi, expect, satbN, ours, verdict))
    out:flush()
    if lastCount > 0 then
      say('f%-5d count=%-3d 글리프 %d word $%04X-$%04X (예상 %d) · SATB %d · 스프라이트 %d  [%s]',
          frame, lastCount, gN, gLo < 0 and 0 or gLo, gHi < 0 and 0 or gHi,
          expect, satbN, ours, verdict)
    end
  end

  gN, gLo, gHi, satbN, fires, lastCount = 0, -1, -1, 0, 0, -1
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:close()
  say('0.5.133 끝 [개입=%s] · 저장 %s', tostring(ENABLE), PATH)
  say('0.5.133 ⚠ 숫자가 맞는데 화면이 그대로면 사슬은 맞되 증상 1 의 원인은 또 다른 것이다')
end, emu.eventType.scriptEnded)

say('SUB 0.5.133-mawr-restore-both armed -- ★개입판 (VDC 에 쓴다.  디스크 무수정)')
say('  $15 가 어떤 값에서든 0 까지 내려오면 MAWR 을 $%04X 로 되돌린다 (개입=%s)',
    WANT_MAWR, tostring(ENABLE))
say('  0.5.126 은 19 에서 시작하는 복원만 잡아서 글리프 업로드를 놓쳤다')
say('  덤프 : ' .. PATH)
