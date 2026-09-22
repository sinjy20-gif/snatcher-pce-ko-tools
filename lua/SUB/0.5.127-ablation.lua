-- SUB 0.5.127 -- 무엇을 빼면 잔해가 사라지는지 하나씩 뺀다  ★개입판
--
-- ⚠ 개입판이다.  VDC 와 제로페이지에 쓴다.  디스크는 안 건드린다.
--
-- 왜 이렇게 가나
-- ---------------------------------------------------------------------------
-- 소거된 것 (다시 세우지 말 것):
--
--     BG 가 우리 자리를 그린다     0.5.118  BAT 0/4096 · 배경타일 $1100-$2BBF
--     복원이 자기 구간을 넘친다    0.5.124  정확히 1216 word $6600-$6ABF
--     청크 카운터가 덮인다         0.5.123  수열 19->0 단조감소
--     MAWR 미복원이 원인이다       0.5.126  ★고쳐도 화면 그대로 (소유자 확인)
--
-- MAWR 사슬 자체는 참이다 (B 가 $6AC0 -> $1000 으로 옮겨갔다).  다만 **사진 2 의
-- 원인이 아니다.**  별개 버그로 살려두고, 여기서는 다른 것을 찾는다.
--
-- 추측을 더 쌓지 않고 **하나씩 빼본다.**  빼서 사라지면 그것이 원인이다.
--
-- 모드
-- ---------------------------------------------------------------------------
--     SUB_ABLATE = 'none'      대조군.  아무것도 안 뺀다
--     SUB_ABLATE = 'short'     복원을 1 청크로 줄인다 ($15 를 19 -> 1 로)
--                              -> $6600 에 64 word 만 쓴다 (원래 1216)
--                              ★ "우리 쓰기가 원인인가" 를 가른다
--     SUB_ABLATE = 'sprites'   복원 구간 동안 스프라이트를 끈다 (CR 의 SB 비트)
--                              -> 잔해가 스프라이트로 그려지는지 가른다
--
-- 기본은 'short' 다.  더 근본적인 갈림길이기 때문이다.
--
-- 읽는 법
-- ---------------------------------------------------------------------------
--     short 에서 잔해가 사라진다/작아진다   ★우리가 $6600 을 덮는 것이 원인이다
--                                           -> 남은 질문은 "누가 그것을 보는가"
--     short 에서도 그대로                   ★우리 쓰기는 원인이 아니다
--                                           -> wipe 나 다른 부작용을 봐야 한다
--                                              (그때 'sprites' 는 볼 필요도 없다)
--
--     sprites 에서 잔해가 사라진다          잔해는 스프라이트가 그린 것이다
--     sprites 에서도 그대로                 스프라이트도 BG 도 아니다.  처음부터 다시
--
-- ⚠ short 의 부작용
--     AC 읽기 포인터가 18 청크분 덜 전진한다.  이후 음성의 백업/복원이 어긋날 수
--     있다.  **진단 한 판용이다.**  이걸로 오래 플레이하고 다른 증상을 보고하지 말 것.
--
-- ⚠ sprites 의 부작용
--     그 프레임 동안 게임 스프라이트도 같이 사라진다.  판정에는 지장 없지만,
--     "스프라이트가 없어졌다" 를 "잔해가 사라졌다" 로 착각하지 말 것.
--     잔해가 있던 **자리**를 볼 것.
--
--   BIOS  build/patch/0.4.6.68/Syscard3_galmuri_0.4.6.68.pce
--   CUE   build/patch/0.4.6.68/Snatcher CD-ROMantic (Japan) [KO].cue
--   Power Cycle -> 이 파일만 로드 -> 같은 장면, 대사를 끝까지
--   ★ 자막이 사라지는 순간을 눈으로 볼 것.  숫자는 보조다
--
-- 산출물  C:/snatcher/dump/ablation_0_5_127_<시각>.tsv

local MODE = rawget(_G, 'SUB_ABLATE') or 'short'

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local ENGINE_LO, ENGINE_HI = 0x5B80, 0x5E1F
local ZP15 = 0x2015
local BIG_HITS = 4000
local SAMPLE_EVERY = 32

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/ablation_0_5_127_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tmode\tA_w\tA_lo\tA_hi\tA_first\tA_last\tB_w\tB_lo\tB_hi\tcr_shadow\tnote\n')

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

local muted = false
local function wr(addr, v) pcall(emu.write, addr, v, MEM) end

-- CR 그림자 (CR 은 write-only 라 우리가 본 마지막 값을 들고 있어야 한다)
local crLo, crHi = nil, nil
local selReg, mawr, incr, pendLo = 0, 0, 1, 0
local function incrFrom(hi) local s = (hi >> 3) & 0x03
  return (s == 0) and 1 or (s == 1) and 32 or (s == 2) and 64 or 128 end

local spritesOff = false
local function setCR(lo, hi)
  muted = true
  wr(0x0000, 0x05)
  wr(0x0002, lo & 0xFF)
  wr(0x0003, hi & 0xFF)
  wr(0x0000, selReg)          -- 원래 선택으로 되돌린다
  muted = false
end

local function spritesDisable()
  if crLo == nil or crHi == nil then return false end
  setCR(crLo & 0xBF, crHi)    -- CR bit6 = SB (스프라이트 활성)
  spritesOff = true
  return true
end

local function spritesRestore()
  if not spritesOff then return end
  setCR(crLo, crHi)
  spritesOff = false
end

local hits, phase = 0, 0
local function newB() return { n = 0, lo = -1, hi = -1, first = -1, last = -1 } end
local A, B = newB(), newB()
local note = ''

emu.addMemoryCallback(function(address, value)
  if muted then return end
  local port = address & 3
  value = (value or 0) & 0xFF
  if port == 0 then selReg = value; return end
  if port == 2 then
    if selReg == 0x00 then pendLo = value
    elseif selReg == 0x05 then crLo = value; incr = incr end
    return
  end
  if selReg == 0x00 then
    mawr = ((value << 8) | pendLo) & 0xFFFF
  elseif selReg == 0x05 then
    crHi = value
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
  if muted then return end
  value = (value or 0) & 0xFF
  if phase == 0 and value == 19 then
    phase = 1
    if MODE == 'short' then
      muted = true
      wr(ZP15, 1)                      -- 19 -> 1.  다음 DEC 에서 0 이 되어 빠진다
      muted = false
      note = '$15=1 로 줄임'
    elseif MODE == 'sprites' then
      note = spritesDisable() and '스프라이트 OFF' or '★CR 그림자없음-못껐다'
    end
  elseif phase == 1 and value == 0 then
    phase = 2
  end
end, emu.callbackType.write, ZP15, ZP15, CPU, MEM)

emu.addMemoryCallback(function() hits = hits + 1 end,
  emu.callbackType.exec, ENGINE_LO, ENGINE_HI, CPU, MEM)

local frame, restores = 0, 0

emu.addEventCallback(function()
  frame = frame + 1

  if hits >= BIG_HITS or A.n > 0 then
    restores = restores + 1
    out:write(string.format('%d\t%s\t%d\t%04X\t%04X\t%d\t%d\t%d\t%04X\t%04X\t%s\t%s\n',
      frame, MODE, A.n, A.lo < 0 and 0 or A.lo, A.hi < 0 and 0 or A.hi,
      A.first, A.last, B.n, B.lo < 0 and 0 or B.lo, B.hi < 0 and 0 or B.hi,
      (crLo and crHi) and string.format('%02X%02X', crHi, crLo) or '-', note))
    out:flush()
    say('RESTORE f%d [%s] %s', frame, MODE, note)
    say('  A %d word $%04X-$%04X line %d..%d   (원래 1216 $6600-$6ABF)',
        A.n, A.lo < 0 and 0 or A.lo, A.hi < 0 and 0 or A.hi, A.first, A.last)
    say('  B %d word $%04X-$%04X', B.n, B.lo < 0 and 0 or B.lo, B.hi < 0 and 0 or B.hi)
  end

  spritesRestore()
  hits, phase, note = 0, 0, ''
  A, B = newB(), newB()
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  spritesRestore()
  out:close()
  say('0.5.127 끝 [%s] -- 복원 %d 회 · 저장 %s', MODE, restores, PATH)
  if restores == 0 then say('0.5.127 ⚠ 복원을 못 봤다.  판정하지 말 것') end
end, emu.eventType.scriptEnded)

say('SUB 0.5.127-ablation armed -- ★개입판.  모드 = %s', MODE)
say('  none    아무것도 안 뺀다 (대조군)')
say('  short   복원을 1 청크로 줄인다 -> "우리 쓰기가 원인인가" 를 가른다')
say('  sprites 복원 동안 스프라이트를 끈다 -> "잔해를 스프라이트가 그리는가"')
say('  바꾸려면 파일 맨 위에서 SUB_ABLATE 를 전역으로 주거나 MODE 기본값을 고칠 것')
say('  덤프 : ' .. PATH)
