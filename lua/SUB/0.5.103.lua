-- SUB 0.5.103 -- "자막 전 스킵" 만 깨지는 이유를 가른다 (가볍게)
--
-- 진리표 (0.5.102 · BIOS 0.4.6.48 실측)
--   노스킵          그림 있음   무개입      정상
--   자막 중간 스킵  그림 있음   state 2->3  정상   (diff 1026/2432 · elapsed 2454)
--   자막 전 스킵    그림 없음   state 2->3  깨짐   (diff    0/2432 · elapsed  121)
--
-- 2·3 번은 똑같이 스킵 직후 즉시 restore+wipe 를 돈다.  2 번이 멀쩡하므로
-- "새 장면 위에 반납" 자체는 무해하다.  갈리는 것은 둘뿐이다.
--   A 안 그렸는데 치웠다  -> 'cancel'
--   B 너무 일러서 끼었다  -> 'delay'   ($8411 직후 게임이 VRAM 세우는 중)
--
-- 판정 (오프닝 뜨자마자 스킵 · 챕터1 화면만 본다)
--   cancel 만 정상  -> A.  안 그렸으면 치우지 않는다
--   delay  만 정상  -> B.  반납을 게임 전송 뒤로 미룬다
--   둘 다 정상      -> 이른 반납이 위험.  A+B 를 같이 건다
--   둘 다 깨짐      -> 파손은 반납이 아니라 빌리는 쪽(save)에서 이미 났다
--
-- ★ 우리 몫은 가볍다: $8411 훅 하나 + 64 바이트 표본.
--   느린 것은 필수 부품인 0.5.77 이다 (뜨거운 $5B83 · 반납마다 7 천 회 API).
--   ⚠ 느리다고 빼면 안 된다 -- 아래 참조.
-- ★ 게임 코드 무수정 · 화면에 아무것도 안 그린다

local MODE  = 'cancel'      -- baseline | skip | cancel | delay
local DELAY = 8             -- 'delay' 에서 미룰 프레임

-- ★★ 0.5.77 은 반드시 같이 올린다 -- 진단 부하가 아니라 **하중을 받는 부품**이다.
--    빼면 0.4.6.48 맨몸이 되어 노스킵·중간 스킵까지 전부 깨진다 (실측).
--    안 그린 케이스에서만 diff=0 이라 무해할 뿐, 그린 케이스에서는 일을 한다.
dofile('C:/snatcher/lua/SUB/0.5.77-refresh-cdda-backup.lua')

local TAG = 'SUB 0.5.103'
local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local VRAM, AC = emu.memType.pceVideoRam, emu.memType.pceArcadeCardRam

local OPENING_SKIP = 0x8411
local TRACK, STATE, SIG, ELAPSED = 0x26F9, 0x7FDF, 0x5DDA, 0x5E1D
local CTL_CMD, CTL_STATUS = 0x5D30, 0x5D31
local CTL_WIPE_SEEN, CTL_WIPE_DONE = 0x5D32, 0x5D33
local AC_BACKUP, TOTAL, CDDA_BASE = 0x1F0400, 2432, 0x7900
local CDDA_TRACK, CDDA_SIG = 0x11, 0x38
local SAMPLES, STRIDE = 64, 38          -- 64 x 38 = 2,432 대역 전체를 훑는다

local frame, pending, acted = 0, nil, 0

local function rb(at) return emu.read(at, MEM) or 0 end
local function say(fmt, ...) emu.log(TAG .. ' · ' .. string.format(fmt, ...)) end

-- 그림이 있나: 대역을 64 점만 찍어 AC 백업과 비교한다 (그린 판은 42% 가 다르다)
local function drawn()
  local at, diff = CDDA_BASE * 2, 0
  for i = 0, SAMPLES - 1 do
    local o = i * STRIDE
    if (emu.read(AC_BACKUP + o, AC) or -1) ~= (emu.read(at + o, VRAM) or 0) then
      diff = diff + 1
    end
  end
  return diff
end

local function requestEnd(why, diff)
  emu.write(STATE, 0x03, MEM)
  acted = acted + 1
  say('%df END_REQ %s · drawn=%d/%d · state $02->$03', frame, why, diff, SAMPLES)
end

emu.addEventCallback(function()
  frame = frame + 1
  if pending and frame >= pending.at then
    requestEnd('delay ' .. DELAY .. 'f', pending.diff)
    pending = nil
  end
end, emu.eventType.endFrame)

emu.addMemoryCallback(function()
  local track, state, sig = rb(TRACK) & 0x7F, rb(STATE), rb(SIG)
  local elapsed = rb(ELAPSED) | (rb(ELAPSED + 1) << 8)

  if track ~= CDDA_TRACK or state ~= 0x02 or sig ~= CDDA_SIG then
    say('%df PASS track=$%02X state=$%02X sig=$%02X elapsed=%d',
        frame, track, state, sig, elapsed)
    return
  end

  local diff = drawn()
  say('%df SKIP@8411 elapsed=%d · drawn=%d/%d · cmd=$%02X status=$%02X',
      frame, elapsed, diff, SAMPLES, rb(CTL_CMD), rb(CTL_STATUS))

  if MODE == 'baseline' then
    requestEnd('baseline', diff)
  elseif MODE == 'delay' then
    pending = { at = frame + DELAY, diff = diff }
    say('%df DEFER %d 프레임 뒤 종료 요청', frame, DELAY)
  elseif diff > 0 then
    requestEnd('drawn', diff)          -- 중간 스킵은 이미 정상 -- 그대로 둔다
  elseif MODE == 'skip' then
    say('%df NO_ACT 안 그렸다 -- 무개입 (늦은 반납이 오는지 본다)', frame)
  elseif MODE == 'cancel' then
    emu.write(CTL_CMD, 0x00, MEM)      -- ★ 치울 게 없다.  반납을 안 시킨다
    emu.write(STATE, 0x00, MEM)
    acted = acted + 1
    say('%df CANCEL 안 그렸다 -- cmd=0 · state=0 으로 반납 취소', frame)
  end
end, emu.callbackType.exec, OPENING_SKIP, OPENING_SKIP, CPU, MEM)

-- 반납이 게임 스프라이트를 지웠나 (헬퍼가 직접 센 값 · 반납당 1회)
emu.addMemoryCallback(function()
  say('%df WIPE seen=%d done=%d', frame, rb(CTL_WIPE_SEEN), rb(CTL_WIPE_DONE))
end, emu.callbackType.write, CTL_WIPE_DONE, CTL_WIPE_DONE, CPU, MEM)

emu.addEventCallback(function()
  say('끝 -- mode=%s · 개입 %d회', MODE, acted)
end, emu.eventType.scriptEnded)

say('loaded -- MODE=%s%s', MODE, MODE == 'delay' and (' DELAY=' .. DELAY) or '')
say('판정: 오프닝 뜨자마자(자막 전) 스킵 -> 챕터1 화면이 멀쩡한가')
