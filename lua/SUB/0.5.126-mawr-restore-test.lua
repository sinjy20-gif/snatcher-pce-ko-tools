-- SUB 0.5.126 -- 복원 직후 MAWR=$1000 을 되돌려 사슬을 확정한다  ★개입판
--
-- ⚠ 이 연쇄에서 **처음으로 읽기 전용이 아니다.**  VDC 에 쓴다.
--   디스크는 안 건드린다.  되돌리기는 이 파일을 안 올리면 끝이다.
--
-- 무엇을 확인하나
-- ---------------------------------------------------------------------------
-- 0.5.124/0.5.125 로 확정된 사슬:
--
--     line 31     게임이 MAWR = $1000 을 잡는다 (SATB 갱신 준비)
--     line 60     우리 복원이 MAWR = $6600 을 잡는다
--     line 60~201 1,216 word.  MAWR 은 $6AC0 에서 멈춘다.  아무도 안 되돌린다
--     line 202    게임($60BA/$650C)이 SATB 256 word 를 MAWR 을 다시 안 잡고 흘린다
--                 -> $6AC0-$6BBF 로 떨어진다 -> 그 프레임 스프라이트 갱신 소실
--
-- 이 판은 `$15` 가 0 이 되는 순간(= 19 번째 청크가 끝난 직후) MAWR 을 $1000 으로
-- 되돌린다.  사슬이 맞다면 게임의 256 word 가 제자리로 간다.
--
-- 판정 -- 눈이 아니라 숫자로 먼저 본다
-- ---------------------------------------------------------------------------
--     B 가 $1000-$10FF 로 간다     ★사슬 확정.  §6 "가" 안이 이 장면에서 유효
--     B 가 여전히 $6AC0            사슬이 틀렸거나 개입 시점이 늦다
--     B 가 제3의 자리              개입이 다른 것을 깨뜨렸다.  즉시 끌 것
--
-- 그리고 **화면도 같이 본다.**  숫자가 맞아도 화면이 그대로면 사슬은 맞되
-- 사진 2 의 원인은 따로 있다는 뜻이다.  둘을 같이 적을 것.
--
-- 왜 $1000 상수인가
-- ---------------------------------------------------------------------------
-- MAWR 은 HuC6270 에서 **write-only** 라 빌리기 전 값을 떠둘 수 없다.
-- 다만 이 장면에서는 상수가 정답이다 -- 게임이 line 31 에 $1000 을 잡고 line 202
-- 까지 한 워드도 안 썼다 (0.5.124 의 pre 36 word 는 전부 우리 wipe).
--
-- ⚠ 다른 장면에서도 $1000 인지는 **안 쟀다.**  이 판은 이 장면의 확인용이지
--   그대로 디스크에 넣을 설계가 아니다.
--
-- 어떻게 되돌리나
-- ---------------------------------------------------------------------------
--     port0 <- $00     MAWR 선택
--     port2 <- $00     하위
--     port3 <- $10     상위      -> MAWR = $1000
--     port0 <- $02     VWR 재선택 (헬퍼가 나갈 때 상태와 같게 되돌린다)
--
-- ★ 마지막 줄이 중요하다.  게임은 selReg 가 $02 인 채로 데이터를 흘린다.
--   $00 인 채로 두면 게임의 데이터가 MAWR 로 들어가 훨씬 크게 깨진다.
--
-- 끄고 켜기
-- ---------------------------------------------------------------------------
--     SUB_MAWR_FIX = false  로 두면 개입 없이 측정만 한다 (0.5.124 와 같은 대조군)
--     기본은 true.
--
--   BIOS  build/patch/0.4.6.68/Syscard3_galmuri_0.4.6.68.pce
--   CUE   build/patch/0.4.6.68/Snatcher CD-ROMantic (Japan) [KO].cue
--   Power Cycle -> 이 파일만 로드 -> 0.5.124 와 같은 장면, 대사를 끝까지
--   ★ 자막이 사라지는 순간을 **눈으로도** 볼 것
--
-- 산출물  C:/snatcher/dump/mawr_fix_0_5_126_<시각>.tsv

local ENABLE = rawget(_G, 'SUB_MAWR_FIX')
if ENABLE == nil then ENABLE = true end

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local ENGINE_LO, ENGINE_HI = 0x5B80, 0x5E1F
local ZP15 = 0x2015
local BIG_HITS = 4000
local SAMPLE_EVERY = 32

local WANT_MAWR = 0x1000

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/mawr_fix_0_5_126_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tenabled\tfix_line\t'
       .. 'A_w\tA_lo\tA_hi\tB_w\tB_lo\tB_hi\tB_first\tB_last\tverdict\n')

local function say(f, ...) emu.log(string.format(f, ...)) end

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

-- ★ 개입.  우리가 쓰는 것도 우리 콜백을 태우므로 그 동안은 집계를 멈춘다
local muted = false
local function writePort(p, v) pcall(emu.write, p, v, MEM) end

local function restoreMawr()
  muted = true
  writePort(0x0000, 0x00)                       -- MAWR 선택
  writePort(0x0002, WANT_MAWR & 0xFF)           -- 하위
  writePort(0x0003, (WANT_MAWR >> 8) & 0xFF)    -- 상위
  writePort(0x0000, 0x02)                       -- VWR 재선택 (★반드시)
  muted = false
end

-- VDC 그림자
local selReg, mawr, incr, pendLo = 0, 0, 1, 0
local function incrFrom(hi) local s = (hi >> 3) & 0x03
  return (s == 0) and 1 or (s == 1) and 32 or (s == 2) and 64 or 128 end

local hits, phase, fixLine = 0, 0, -1
local function newB() return { n = 0, lo = -1, hi = -1, first = -1, last = -1 } end
local A, B = newB(), newB()

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
    local b = (phase == 1) and A or (phase == 2) and B or nil
    if b then
      b.n = b.n + 1
      if b.lo < 0 or a < b.lo then b.lo = a end
      if b.hi < 0 or a > b.hi then b.hi = a end
      if b.n == 1 or b.n % SAMPLE_EVERY == 0 then
        local l = scanline()
        if b.first < 0 then b.first = l end
        b.last = l
      end
    end
    mawr = (mawr + incr) & 0xFFFF
  end
end, emu.callbackType.write, 0x0000, 0x0003, CPU, MEM)

emu.addMemoryCallback(function(address, value)
  value = (value or 0) & 0xFF
  if phase == 0 and value == 19 then
    phase = 1
  elseif phase == 1 and value == 0 then
    phase = 2
    fixLine = scanline()
    if ENABLE then
      restoreMawr()
      mawr = WANT_MAWR                 -- 그림자도 같이 맞춘다
    end
  end
end, emu.callbackType.write, ZP15, ZP15, CPU, MEM)

emu.addMemoryCallback(function() hits = hits + 1 end,
  emu.callbackType.exec, ENGINE_LO, ENGINE_HI, CPU, MEM)

local frame, restores, fixed, stillBad = 0, 0, 0, 0

emu.addEventCallback(function()
  frame = frame + 1

  if hits >= BIG_HITS then
    restores = restores + 1
    local verdict
    if B.n == 0 then verdict = 'B없음'
    elseif B.lo >= 0x1000 and B.hi <= 0x10FF then verdict = '★제자리로-간다'; fixed = fixed + 1
    elseif B.lo >= 0x6A00 then verdict = '여전히-우리자리'; stillBad = stillBad + 1
    else verdict = '★제3의자리-즉시끌것'; stillBad = stillBad + 1 end

    out:write(string.format('%d\t%s\t%d\t%d\t%04X\t%04X\t%d\t%04X\t%04X\t%d\t%d\t%s\n',
      frame, tostring(ENABLE), fixLine,
      A.n, A.lo < 0 and 0 or A.lo, A.hi < 0 and 0 or A.hi,
      B.n, B.lo < 0 and 0 or B.lo, B.hi < 0 and 0 or B.hi,
      B.first, B.last, verdict))
    out:flush()

    say('RESTORE f%d  개입=%s  MAWR 되돌린 line %d', frame, tostring(ENABLE), fixLine)
    say('  A %d word $%04X-$%04X', A.n, A.lo < 0 and 0 or A.lo, A.hi < 0 and 0 or A.hi)
    say('  B %d word $%04X-$%04X  line %d..%d', B.n, B.lo < 0 and 0 or B.lo,
        B.hi < 0 and 0 or B.hi, B.first, B.last)
    say('  [%s]', verdict)
    say('')
  end

  hits, phase, fixLine = 0, 0, -1
  A, B = newB(), newB()
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:close()
  say('0.5.126 끝 -- 복원 %d 회 · 제자리 %d · 여전히 %d', restores, fixed, stillBad)
  if restores == 0 then say('0.5.126 ⚠ 복원을 못 봤다.  판정하지 말 것') end
  say('0.5.126 ⚠ 숫자가 맞아도 화면이 그대로면, 사슬은 맞되 사진 2 의 원인은 따로다.'
      .. ' 눈으로 본 것을 같이 적을 것')
  say('0.5.126 저장 %s', PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.126-mawr-restore-test armed -- ★개입판 (VDC 에 쓴다.  디스크는 무수정)')
say('  $15 가 0 이 되는 순간 MAWR 을 $%04X 로 되돌린다  (개입=%s)',
    WANT_MAWR, tostring(ENABLE))
say('  SUB_MAWR_FIX = false 로 두면 개입 없이 대조군으로 돈다')
say('  ★ 자막이 사라지는 순간을 눈으로도 볼 것')
say('  덤프 : ' .. PATH)
