-- CDDA 0.5.0 -- 0.6.0-rc13-latch-track 전용
--
-- 순수 관측.  메모리와 화면을 바꾸지 않는다.
--
-- rc12 와 무엇이 다른가
-- --------------------
-- 완료 표식이 AC 두 바이트가 됐다.
--   $1F1EE7  서명 $A5
--   $1F1EE8  그 표식을 찍은 트랙 (BCD)      ★rc13 에서 추가
--
-- 관문이 서명만 보고 막던 것을 트랙까지 보고 막는다.
--   LDA $1A10 / CMP #$A5  / BNE fresh      서명 없음   -> 통과
--   LDA $1A10 / CMP $20A2 / BNE fresh      다른 트랙   -> 통과   ★추가
--   (아래로)                                같은 트랙   -> 철수
--
-- ⚠ rc12 프로브(0.3.0)를 그대로 쓰면 안 된다.  스케줄러가 +6, dispatcher 가
--   +8 늘어 세 주소가 밀렸다:  SUPPRESS $F941->$F949 · FRESH $F944->$F94C ·
--   STOPPED $EF12->$EF18.
--
-- 판정
-- ----
--   트랙 17   ARM 1 · MARK_DONE 1 (mark_track=17)
--   트랙 19   LATCH_HIT 1 이상 + FRESH.  SUPPRESS 0        ★이번에 고친 것
--   트랙 20   LATCH_HIT + SUPPRESS (같은 트랙 재무장 거부)  ★원래 잡던 것
--   그 뒤     ADPCM_ARM 1 이상

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local STATE, ADPCM_STATE = 0x5E1A, 0x7FDF
local SUBQ_TRACK = 0x20A2          -- 지금 트랙 (BCD).  관문이 비교하는 그것
local ARMED_TRACK = 0x5E1B         -- 무장된 트랙 (BCD)
local RAW_TRACK = 0x26F9           -- CD_SUBQ raw (16진이 아니라 2진)

local PC_BOOT_CLEAR    = 0xF3AE    -- cdda_done_boot_clear
local PC_REQUEST_CLEAR = 0xF879    -- cdda_done_request_clear (= rom_cdda_init)
local PC_START         = 0xF8DE    -- cdda_start
local PC_LATCH_HIT     = 0xF921    -- ★신규.  서명이 $A5 였다 -> 트랙 비교로 간다
local PC_SUPPRESS      = 0xF949    -- cdda_done_suppress   (rc12 $F941)
local PC_FRESH         = 0xF94C    -- cdda_playback_fresh  (rc12 $F944)
local PC_MARK_DONE     = 0xEEE3    -- cdda_mark_done
local PC_STOPPED       = 0xEF18    -- cdda_stopped         (rc12 $EF12)
local PC_REQUEST       = 0xFE8F    -- cache_save

local stamp = os.date('%Y%m%d_%H%M%S')
local path = 'C:/snatcher/dump/cdda_latch_0_5_0_' .. stamp .. '.tsv'
local out = assert(io.open(path, 'w'))
out:write('frame\tkind\tcdda_state\tlatch\tmark_track\tsubq_bcd\tarmed_bcd\traw\t' ..
          'p263c\tp2638\tadpcm_state\tnote\n')

local frame, rows = 0, 0
local latch, mark_track = -1, -1     -- 우리가 따라 그리는 AC 두 바이트
local n = { boot_clear=0, request=0, request_clear=0, start=0, fresh=0, latch_hit=0,
            suppress=0, mark=0, stopped=0, arm=0, adpcm_arm=0 }

local function rb(a) return emu.read(a, MEM, false) or 0 end
local function say(s) emu.log(s); print(s) end
local function hx(v) return v < 0 and '?' or string.format('%02X', v) end

local function row(kind, note)
  out:write(string.format('%d\t%s\t%02X\t%s\t%s\t%02X\t%02X\t%02X\t%02X\t%02X\t%02X\t%s\n',
    frame, kind, rb(STATE), hx(latch), hx(mark_track),
    rb(SUBQ_TRACK), rb(ARMED_TRACK), rb(RAW_TRACK),
    rb(0x263C), rb(0x2638), rb(ADPCM_STATE), note or ''))
  rows = rows + 1
  if rows % 16 == 0 then out:flush() end
end

local LOUD = { BOOT_CLEAR=true, REQUEST_CLEAR=true, MARK_DONE=true,
               LATCH_HIT=true, SUPPRESS=true, FRESH=true, STOPPED=true }

local function onExec(addr, kind, key, effect)
  emu.addMemoryCallback(function()
    if effect == 'clear' then
      latch, mark_track = 0, -1
    elseif effect == 'mark' then
      -- 코드가 $A5 를 쓰고 바로 $20A2 를 같은 포트에 흘린다 (자동증가).
      latch, mark_track = 0xA5, rb(SUBQ_TRACK)
    end
    n[key] = n[key] + 1
    row(kind, '')
    if LOUD[kind] then
      say(string.format('f%-7d %-13s state=%02X latch=%s mark=%s subq=%02X raw=%02X',
        frame, kind, rb(STATE), hx(latch), hx(mark_track), rb(SUBQ_TRACK), rb(RAW_TRACK)))
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
    'latch_hit=%d suppress=%d fresh=%d adpcm_arm=%d',
    frame, n.boot_clear, n.request_clear, n.arm, n.mark, n.stopped,
    n.latch_hit, n.suppress, n.fresh, n.adpcm_arm)
  out:write('#\n# ' .. s .. '\n'); out:close()
  say(''); say('CDDA 0.5.0 끝  ' .. s); say('-> ' .. path)
end, emu.eventType.scriptEnded)

say('CDDA 0.5.0 트랙 붙은 완료 표식 관측 시작')
say('시험판: 0.6.0-rc13-latch-track')
say('  LATCH_HIT 뒤 FRESH = 다른 트랙이라 통과 (트랙 19 에서 이게 보여야 한다)')
say('  LATCH_HIT 뒤 SUPPRESS = 같은 트랙이라 거부 (트랙 20 재무장에서 이게 맞다)')
say('-> ' .. path)
