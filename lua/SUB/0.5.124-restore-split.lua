-- SUB 0.5.124 -- 1216 과 256 이 어디서 갈리는지만 찍는다 (쓰기 0 B)
--
-- 왜 이것만 보나
-- ---------------------------------------------------------------------------
-- 0.5.123 으로 정리된 것:
--
--     $15 IRQ 충돌      기각.  수열이 19@55 ... 1@193 0@201 로 단조감소했다
--     23 청크 restore   기각.  루프는 정확히 19 번 돌았다
--     19 청크 + 정체불명 추가 512 B   <- 새 1 순위
--
-- MAWR 은 $6600 에 한 번만 잡히고 아무도 다시 안 잡았다.  자동증가라 우리 전송이
-- 끝난 자리($6AC0)에 그대로 서 있다.  그 뒤에 256 word 가 더 들어갔다.
--
-- 그래서 **$15 가 0 이 되는 순간**을 경계로 VDC 쓰기를 둘로 가르기만 하면 된다.
--
-- 판정
-- ---------------------------------------------------------------------------
--     A 1216 · B 256          ★ 복원 뒤에 별도의 512 B 전송이 붙어 있다.  A 확정
--     A 1472 · B 0            청크당 128 B 라는 전제가 틀렸다.  거기부터 다시
--     A 1216 · B 0            이 프레임엔 추가 전송이 없었다.  다른 프레임을 볼 것
--
-- ⚠ B 는 이 판으로 안 사라진다
--     $15 가 정상이어도 19 청크만으로 line 55->201 을 먹는다.  게임을 굶기는
--     문제는 그대로다.  이 판은 A 만 가른다.
--
-- ★ 구간 분류(regLo)를 아예 안 쓴다.  0.5.121~123 이 세 판 연속 그 칸을 죽은 값으로
--   냈다 -- control block 을 직전 프레임 끝에 읽어 base 가 아직 0 이었다.
--   여기서는 주소를 그냥 min/max 로 찍으므로 그 버그가 들어올 자리가 없다.
--
-- ★ 화면에 아무것도 안 그린다.  게임을 한 바이트도 안 고친다.
--
--   BIOS  build/patch/0.4.6.68/Syscard3_galmuri_0.4.6.68.pce
--   CUE   build/patch/0.4.6.68/Snatcher CD-ROMantic (Japan) [KO].cue
--   Power Cycle -> 이 파일만 로드 -> 0.5.123 과 같은 장면, 대사를 끝까지
--
-- 산출물  C:/snatcher/dump/restore_split_0_5_124_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local ENGINE_LO, ENGINE_HI = 0x5B80, 0x5E1F
local ZP15 = 0x2015
local BIG_HITS = 4000
local SAMPLE_EVERY = 32

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/restore_split_0_5_124_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tentry_line\tzero_line\t'
       .. 'pre_w\tA_w\tA_lo\tA_hi\tA_first\tA_last\t'
       .. 'B_w\tB_lo\tB_hi\tB_first\tB_last\tverdict\n')

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

local function newBucket()
  return { n = 0, lo = -1, hi = -1, first = -1, last = -1 }
end

local function add(b, addr)
  b.n = b.n + 1
  if b.lo < 0 or addr < b.lo then b.lo = addr end
  if b.hi < 0 or addr > b.hi then b.hi = addr end
  if b.n == 1 or b.n % SAMPLE_EVERY == 0 then
    local l = scanline()
    if b.first < 0 then b.first = l end
    b.last = l
  end
end

-- VDC 그림자
local selReg, mawr, incr, pendLo = 0, 0, 1, 0
local function incrFrom(hi) local s = (hi >> 3) & 0x03
  return (s == 0) and 1 or (s == 1) and 32 or (s == 2) and 64 or 128 end

local hits = 0
local phase = 0                      -- 0 루프 이전 · 1 (19->0) · 2 그 이후
local entryLine, zeroLine = -1, -1
local pre, A, B = newBucket(), newBucket(), newBucket()

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
    add(phase == 0 and pre or phase == 1 and A or B, a)
    mawr = (mawr + incr) & 0xFFFF
  end
end, emu.callbackType.write, 0x0000, 0x0003, CPU, MEM)

emu.addMemoryCallback(function(address, value)
  value = (value or 0) & 0xFF
  if phase == 0 and value == 19 then
    phase = 1
    entryLine = scanline()
  elseif phase == 1 and value == 0 then
    phase = 2
    zeroLine = scanline()
  end
end, emu.callbackType.write, ZP15, ZP15, CPU, MEM)

emu.addMemoryCallback(function() hits = hits + 1 end,
  emu.callbackType.exec, ENGINE_LO, ENGINE_HI, CPU, MEM)

local frame, restores = 0, 0

emu.addEventCallback(function()
  frame = frame + 1

  if hits >= BIG_HITS then
    restores = restores + 1
    local verdict
    if A.n >= 1400 and B.n == 0 then verdict = '★청크전제-재검토(A가1472)'
    elseif B.n > 0 then verdict = '★복원뒤-별도전송'
    else verdict = '추가전송-없음' end

    out:write(string.format('%d\t%d\t%d\t%d\t%d\t%04X\t%04X\t%d\t%d\t%d\t%04X\t%04X\t%d\t%d\t%s\n',
      frame, entryLine, zeroLine, pre.n,
      A.n, A.lo < 0 and 0 or A.lo, A.hi < 0 and 0 or A.hi, A.first, A.last,
      B.n, B.lo < 0 and 0 or B.lo, B.hi < 0 and 0 or B.hi, B.first, B.last, verdict))
    out:flush()

    say('RESTORE f%d', frame)
    say('loop 진입        line %d', entryLine)
    if pre.n > 0 then
      say('  (루프 이전)    words=%d  addr=$%04X-$%04X  line=%d..%d',
          pre.n, pre.lo, pre.hi, pre.first, pre.last)
    end
    say('')
    say('$15 19->0 구간')
    say('  words=%d', A.n)
    say('  addr=$%04X-$%04X', A.lo < 0 and 0 or A.lo, A.hi < 0 and 0 or A.hi)
    say('  line=%d..%d', A.first, A.last)
    say('')
    say('$15=0 이후 ~ helper 종료')
    say('  words=%d', B.n)
    say('  addr=$%04X-$%04X', B.lo < 0 and 0 or B.lo, B.hi < 0 and 0 or B.hi)
    say('  line=%d..%d', B.first, B.last)
    say('  [%s]', verdict)
    say('')
  end

  hits, phase = 0, 0
  entryLine, zeroLine = -1, -1
  pre, A, B = newBucket(), newBucket(), newBucket()
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:close()
  say('0.5.124 끝 -- 복원 %d 회 · 저장 %s', restores, PATH)
  if restores == 0 then say('0.5.124 ⚠ 복원을 못 봤다.  판정하지 말 것') end
end, emu.eventType.scriptEnded)

say('SUB 0.5.124-restore-split armed -- 순수 관측 · 게임 무수정 · 화면 무개입')
say('  $15 가 0 이 되는 순간을 경계로 VDC 쓰기를 둘로 가른다')
say('  덤프 : ' .. PATH)
