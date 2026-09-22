-- CDDA 0.6.0 -- 0.6.0-rc14-latch-rawtrack 전용
--
-- 순수 관측.  메모리와 화면을 바꾸지 않는다.
--
-- rc13 에서 무엇이 바뀌었나
-- ------------------------
-- 표식의 트랙 키를 $20A2(BCD) 에서 **$26F9 & $7F** 로 바꿨다.
-- 디렉터리 조회($F8C4 LDA $26F9 / AND #$7F)와 같은 키다.
--
-- 왜  rc13 실기 f87812 에서 둘이 어긋났다:
--       $20A2 = 21 (다음 트랙)      $26F9 = $14 (=20, 아직 옛 트랙)
--     관문은 $20A2 를 봐서 "새 트랙" 이라며 열었고, 조회는 $26F9 를 봐서
--     **트랙 20 을 다시 무장**했다 (armed_bcd 가 21 이 아니라 20 으로 남았다).
--     이중재생이 1 프레임 뒤로 옮겨간 것뿐이었다.
--
-- ⚠ rc13 프로브(0.5.0)를 그대로 쓰면 안 된다.  주소가 또 밀렸다:
--     SUPPRESS $F949->$F94B · FRESH $F94C->$F94E · STOPPED $EF18->$EF1A
--
-- 판정
-- ----
--   트랙 17   ARM · MARK_DONE (mark=11)                       ※mark 는 이제 16진 raw
--   트랙 19   LATCH_HIT + FRESH · SUPPRESS 0                  고친 것 ①
--   트랙 20   LATCH_HIT + SUPPRESS 다수 · 두 번째 ARM 없음      원래 잡던 것
--   ★트랙 20 이 끝나는 프레임   subq 가 먼저 튀어도 raw 가 그대로면 SUPPRESS 유지
--     (rc13 은 여기서 FRESH 로 새어 트랙 20 을 다시 물었다)
--   그 뒤     ADPCM_ARM 1 이상

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local STATE, ADPCM_STATE = 0x5E1A, 0x7FDF
local SUBQ_TRACK = 0x20A2          -- BCD.  이제 관문은 이걸 안 본다 (대조용으로만 찍는다)
local ARMED_TRACK = 0x5E1B         -- 무장된 트랙 (BCD)
local RAW_TRACK = 0x26F9           -- ★관문과 조회가 함께 쓰는 키 (하위 7 비트)

local PC_BOOT_CLEAR    = 0xF3AE
local PC_REQUEST_CLEAR = 0xF879
local PC_START         = 0xF8DE
local PC_LATCH_HIT     = 0xF921    -- 서명이 $A5 였다 -> 트랙 비교로 간다
local PC_SUPPRESS      = 0xF94B    -- rc13 $F949
local PC_FRESH         = 0xF94E    -- rc13 $F94C
local PC_MARK_DONE     = 0xEEE3
local PC_STOPPED       = 0xEF1A    -- rc13 $EF18
local PC_REQUEST       = 0xFE8F

local stamp = os.date('%Y%m%d_%H%M%S')
local path = 'C:/snatcher/dump/cdda_latch_0_6_0_' .. stamp .. '.tsv'
local out = assert(io.open(path, 'w'))
out:write('frame\tkind\tcdda_state\tlatch\tmark_raw\traw\tsubq_bcd\tarmed_bcd\t' ..
          'skew\tp263c\tp2638\tadpcm_state\tnote\n')

local frame, rows = 0, 0
local latch, mark_raw = -1, -1
local n = { boot_clear=0, request=0, request_clear=0, start=0, fresh=0, latch_hit=0,
            suppress=0, mark=0, stopped=0, arm=0, adpcm_arm=0, skew=0 }

local function rb(a) return emu.read(a, MEM, false) or 0 end
local function say(s) emu.log(s); print(s) end
local function hx(v) return v < 0 and '?' or string.format('%02X', v) end
local function bcd(v) return (v >> 4) * 10 + (v & 0x0F) end

-- $20A2 는 BCD, $26F9 는 2진.  같은 트랙이면 십진값이 같아야 한다.
local function skewed()
  local s, r = rb(SUBQ_TRACK), rb(RAW_TRACK) & 0x7F
  -- 재생 전에는 $20A2 가 00 인데 $26F9 에 옛 값이 남아 있어 헛 SKEW 가 뜬다.
  -- 둘 중 하나가 0 이면 아직 트랙을 말하는 상태가 아니다.
  if s == 0 or r == 0 then return false end
  return bcd(s) ~= r
end

local function row(kind, note)
  local sk = skewed()
  if sk then n.skew = n.skew + 1 end
  out:write(string.format('%d\t%s\t%02X\t%s\t%s\t%02X\t%02X\t%02X\t%s\t%02X\t%02X\t%02X\t%s\n',
    frame, kind, rb(STATE), hx(latch), hx(mark_raw),
    rb(RAW_TRACK), rb(SUBQ_TRACK), rb(ARMED_TRACK), sk and 'SKEW' or '',
    rb(0x263C), rb(0x2638), rb(ADPCM_STATE), note or ''))
  rows = rows + 1
  if rows % 16 == 0 then out:flush() end
end

-- LATCH_HIT/SUPPRESS 는 트랙 하나에 수백 번 나온다.  SKEW 인 것만 시끄럽게 한다
-- (rc13 이 새던 바로 그 프레임이다).  나머지는 TSV 에만 남는다.
local LOUD = { BOOT_CLEAR=true, REQUEST_CLEAR=true, MARK_DONE=true,
               FRESH=true, STOPPED=true }
local LOUD_IF_SKEW = { LATCH_HIT=true, SUPPRESS=true }

local function onExec(addr, kind, key, effect)
  emu.addMemoryCallback(function()
    if effect == 'clear' then
      latch, mark_raw = 0, -1
    elseif effect == 'mark' then
      latch, mark_raw = 0xA5, rb(RAW_TRACK) & 0x7F
    end
    n[key] = n[key] + 1
    row(kind, '')
    -- SUPPRESS 는 트랙 하나에 수백 번 나온다.  그중 skew 인 것만 시끄럽게 한다
    -- (rc13 이 새던 바로 그 프레임이다).
    if LOUD[kind] or (LOUD_IF_SKEW[kind] and skewed()) then
      say(string.format('f%-7d %-13s state=%02X latch=%s mark=%s raw=%02X subq=%02X%s',
        frame, kind, rb(STATE), hx(latch), hx(mark_raw),
        rb(RAW_TRACK), rb(SUBQ_TRACK), skewed() and '  <- SKEW' or ''))
    end
  end, emu.callbackType.exec, addr, addr, CPU, MEM)
end

onExec(PC_BOOT_CLEAR,    'BOOT_CLEAR',    'boot_clear',    'clear')
onExec(PC_REQUEST,       'REQUEST',       'request',       nil)
onExec(PC_REQUEST_CLEAR, 'REQUEST_CLEAR', 'request_clear', 'clear')
onExec(PC_START,         'START',         'start',         nil)
onExec(PC_LATCH_HIT,     'LATCH_HIT',     'latch_hit',     nil)
onExec(PC_FRESH,         'FRESH',         'fresh',         nil)
onExec(PC_MARK_DONE,     'MARK_DONE',     'mark',          'mark')
onExec(PC_STOPPED,       'STOPPED',       'stopped',       nil)
onExec(PC_SUPPRESS,      'SUPPRESS',      'suppress',      nil)

emu.addMemoryCallback(function(_addr, value)
  if value == 2 then n.arm = n.arm + 1; row('ARM', 'cdda state=2')
  elseif value == 0 then row('CDDA_STATE0', '')
  else row('CDDA_STATE', string.format('value=%02X', value)) end
end, emu.callbackType.write, STATE, STATE, CPU, MEM)

emu.addMemoryCallback(function(_addr, value)
  if value == 1 then n.adpcm_arm = n.adpcm_arm + 1; row('ADPCM_ARM', '')
  elseif value == 0 then row('ADPCM_STATE0', '') end
end, emu.callbackType.write, ADPCM_STATE, ADPCM_STATE, CPU, MEM)

emu.addEventCallback(function() frame = frame + 1 end, emu.eventType.endFrame)
emu.addEventCallback(function()
  local s = string.format(
    'frames=%d boot_clear=%d request_clear=%d arm=%d mark=%d stopped=%d ' ..
    'latch_hit=%d suppress=%d fresh=%d adpcm_arm=%d skew_rows=%d',
    frame, n.boot_clear, n.request_clear, n.arm, n.mark, n.stopped,
    n.latch_hit, n.suppress, n.fresh, n.adpcm_arm, n.skew)
  out:write('#\n# ' .. s .. '\n'); out:close()
  say(''); say('CDDA 0.6.0 끝  ' .. s); say('-> ' .. path)
  say('  ★ FRESH 가 SKEW 프레임에 나오면 rc13 의 새는 구멍이 남은 것이다')
end, emu.eventType.scriptEnded)

say('CDDA 0.6.0 raw 트랙 키 관측 시작')
say('시험판: 0.6.0-rc14-latch-rawtrack')
say('  mark/raw 는 16진 raw 다 ($11=17 · $13=19 · $14=20)')
say('  SKEW = $20A2 와 $26F9 가 다른 트랙을 가리키는 프레임')
say('  그런 프레임에 FRESH 가 뜨면 안 된다')
say('-> ' .. path)
