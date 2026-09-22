-- SUB 0.5.9 -- 백업/복원 왕복이 손실 없는지 잰다 (쓰기 0 B)
--
-- 왜
-- ---------------------------------------------------------------------------
-- 0.4.6.16 에서 헬퍼의 백업/복원 대상이 $7900 -> $1600 으로 바로잡혔다.
-- 그랬더니 복원이 **실제로 동작하되 내용이 틀린다** -- 대사 종료 후 "약간 UI 가
-- 깨진 듯한 이전 내용" 이 돌아온다.  $7900 을 되돌리던 동안에는 아무도 안 보는
-- 자리라 이 결함이 보이지 않았다.  주소를 고치니 잠복 버그가 드러난 것이다.
--
-- "전혀 다른 내용" 이 아니라 "비슷한데 어긋난" 모양이면 보통 셋 중 하나다.
--
--   ① VDC 증가폭(CR $05)   헬퍼는 CR 을 안 세운다.  게임이 남긴 증가폭이 1 이
--                          아니면 읽기/쓰기가 건너뛰며 흩어진다
--   ② VRAM 읽기 프리페치    MARR 설정 후 첫 워드가 한 칸 밀리는 고전적 함정
--   ③ 백업 시점            우리 글자가 이미 올라간 뒤 백업했다면 글자를 저장했다가
--                          다시 칠하는 셈이 된다
--
-- 이 판은 셋 중 무엇인지 고르지 않는다.  **왕복이 손실 없는지부터** 잰다.
--
-- 무엇을 재나
-- ---------------------------------------------------------------------------
--     A  음성 시작 직전(헬퍼가 백업하기 전)의 VRAM $1600-$1ABF  2,432 B
--     B  음성 종료 뒤 복원이 끝난 시점의 같은 구간
--
-- A == B 여야 정상이다.  다르면 어떻게 다른지까지 낸다:
--
--     다른 워드 수 · 첫 어긋난 워드
--     ±1 · ±2 워드 시프트로 맞아떨어지는가   -> ② 프리페치/오프바이원
--     32 워드 간격으로만 맞는가              -> ① 증가폭
--     A 가 이미 글리프처럼 보이는가          -> ③ 백업 시점
--
-- ★ 표본이 0 이면 판정하지 말 것.
--
-- Power Cycle 뒤 이 파일 하나만 로드한다.  대사를 몇 개 흘리고 끝까지 둔다.

assert(rawget(_G, 'SUB_FRAGMENT_FORCE_KEY') == nil and
       rawget(_G, 'SUB_FRAGMENT_FORCE_BASE') == nil,
       '재무장 엔진에서는 SUB_FRAGMENT_FORCE_KEY/BASE 를 쓸 수 없다')

dofile('C:/snatcher/lua/SUB/0.4.89-vdc-rearm.lua')

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local VRAM = emu.memType.pceVideoRam

local PAT_VRAM = 0x1600                 -- word
local WORDS = 19 * 0x40                 -- 1216 word = 2432 B
local BYTE_AT, BYTE_LEN = PAT_VRAM * 2, WORDS * 2

-- 헬퍼 save 루프의 첫 전송.  여기 닿기 **전**이 원본 상태다.
local SAVE_LOOP = 0x5BAE
local SETTLE = 20                       -- 음성 종료 후 복원이 끝나길 기다리는 프레임

local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/roundtrip_0_5_9_' .. STAMP .. '.tsv'
local out = io.open(OUT, 'w')
if out then
  out:write('voice\tkey\tdiff_words\tfirst_bad\tshift_hit\tstride32\tbefore_nonzero\n')
end

local function snap()
  local t = {}
  for i = 0, BYTE_LEN - 1 do t[i + 1] = emu.read(BYTE_AT + i, VRAM) or 0 end
  return t
end

local function words(t)
  local w = {}
  for i = 1, WORDS do w[i] = t[i * 2 - 1] | (t[i * 2] << 8) end
  return w
end

-- a 를 n 워드 밀어 b 와 맞는 비율
local function shiftMatch(a, b, n)
  local ok, total = 0, 0
  for i = 1, WORDS do
    local j = i + n
    if j >= 1 and j <= WORDS then
      total = total + 1
      if a[i] == b[j] then ok = ok + 1 end
    end
  end
  return (total > 0) and (ok / total) or 0
end

local before, beforeKey = nil, '-'
local voices = 0
local curKey = '-'

local prevLog = emu.log
emu.log = function(message, ...)
  local key = tostring(message):match('KEY #%d+ (%x+)')
  if key then curKey = key end
  return prevLog(message, ...)
end

-- save 루프에 처음 닿기 직전에 원본을 뜬다 (음성당 1 회).
emu.addMemoryCallback(function()
  if before == nil then
    before = snap()
    beforeKey = curKey
  end
end, emu.callbackType.exec, SAVE_LOOP, SAVE_LOOP, CPU, MEM)

local function voicePlaying()
  local ok, s = pcall(emu.getState)
  if not ok or not s then return nil end
  return s['cdrom.adpcm.playing'] == true
end

local wasPlaying, idle = false, 0

emu.addEventCallback(function()
  local playing = voicePlaying() == true
  if playing then
    wasPlaying = true
    idle = 0
  elseif wasPlaying then
    idle = idle + 1
    if idle >= SETTLE then
      wasPlaying = false
      if before then
        voices = voices + 1
        local a = words(before)
        local b = words(snap())
        local diff, firstBad = 0, -1
        for i = 1, WORDS do
          if a[i] ~= b[i] then
            diff = diff + 1
            if firstBad < 0 then firstBad = i - 1 end
          end
        end
        local nonzero = 0
        for i = 1, WORDS do if a[i] ~= 0 then nonzero = nonzero + 1 end end

        local shiftHit, shiftN = 0, 0
        for _, n in ipairs({-2, -1, 1, 2}) do
          local r = shiftMatch(a, b, n)
          if r > shiftHit then shiftHit, shiftN = r, n end
        end
        local stride = 0
        for i = 1, WORDS, 32 do if a[i] == b[i] then stride = stride + 1 end end
        stride = stride / math.ceil(WORDS / 32)

        prevLog(string.format(
          'SUB 0.5.9 #%d · KEY %s · 다른 워드 %d/%d · 첫 어긋남 +%d · ' ..
          '시프트 %+d 일치 %.0f%% · 32간격 일치 %.0f%% · 백업 비영 %d',
          voices, beforeKey, diff, WORDS, firstBad, shiftN, shiftHit * 100,
          stride * 100, nonzero))
        if diff == 0 then
          prevLog('   -> 왕복 무손실.  복원 자체는 정상이다')
        elseif shiftHit > 0.8 then
          prevLog('   -> ★ 시프트로 대부분 맞는다.  프리페치/오프바이원 계열')
        elseif stride > 0.8 then
          prevLog('   -> ★ 32 워드 간격으로만 맞는다.  VDC 증가폭(CR) 계열')
        else
          prevLog('   -> 시프트도 간격도 아니다.  백업 시점/범위를 봐야 한다')
        end
        if out then
          out:write(string.format('%d\t%s\t%d\t%d\t%.3f\t%.3f\t%d\n',
            voices, beforeKey, diff, firstBad, shiftHit, stride, nonzero))
          out:flush()
        end
      end
      before = nil
    end
  end

  emu.drawString(4, 74, string.format('0.5.9 왕복검사 %d회 · 구간 $%04X-$%04X (%d word)',
                 voices, PAT_VRAM, PAT_VRAM + WORDS - 1, WORDS), 0x80FF80, 0x000000)
end, emu.eventType.endFrame)

prevLog('SUB 0.5.9-backup-roundtrip armed -- 백업 전 / 복원 후 VRAM 을 비교한다')
prevLog(string.format('  $%04X-$%04X  %d word (%d B) · save 루프 $%04X 직전에 원본을 뜬다',
                      PAT_VRAM, PAT_VRAM + WORDS - 1, WORDS, BYTE_LEN, SAVE_LOOP))
prevLog('  ★ 왕복검사 0 회면 판정하지 말 것')
prevLog('  로그: ' .. OUT)
