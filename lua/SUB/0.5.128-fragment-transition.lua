-- SUB 0.5.128 -- 조각 전환을 잰다 (증상 1).  ★문턱을 없앤 판 (쓰기 0 B)
--
-- ★ 열 판 내내 놓친 것
-- ---------------------------------------------------------------------------
-- 0.5.115 부터 0.5.127 까지 전부 `hits >= 4000` 으로 걸렀다.  그건 **복원(음성 종료)**
-- 만 잡는 문턱이다.  0.5.115 가 이미 조각 전환 프레임을 보여줬는데도 버렸다:
--
--     hits  734~1487 · span 31~69 · line 3~97      글리프 업로드
--     hits  111      · span 81~85 · line 83~173    ★자막 띠를 가로지른다
--
-- 둘 다 문턱 아래다.  **증상 1 은 한 번도 측정된 적이 없다.**
-- 0.5.127 의 'short'(복원을 1 청크로) 가 아무 영향이 없던 것도 당연하다 --
-- 조각 전환에는 복원이 안 돈다.
--
-- 증상 둘
-- ---------------------------------------------------------------------------
--     증상 1  조각 전환   앞 조각 글자가 x 격자로 끼어든다      ← 이 판
--     증상 2  음성 종료   가운데 잔해 띠                        ← 0.5.115~127
--
-- 증상 1 은 팩 자료로 이미 재현됐다 (2026-09-02):
--
--     조각 1  '금일부로 JUNKER로 임명된' 16칸  x=0 10 20 30 40 44 49 55 61 67 72 78 88 92 102 112
--     조각 2  '길리언 시드다만.'          9칸  x=0 10 20 30 34 44 54 64 74
--     겹치면  길리언 시 드U다NK만ER.로 임명된
--
-- Galmuri9 는 비례폭이라 조각마다 x 격자가 다르다.  조각 2 가 안 덮는 자리
-- (49·55·61·67·72·78 · 88·92·102·112)가 살아남으면 정확히 이 그림이 된다.
--
-- 무엇을 재나 -- 문턱 없이 전부
-- ---------------------------------------------------------------------------
-- 우리 코드가 조금이라도 돈 프레임을 **전부** 기록한다 (idle 27 히트는 뺀다).
--
--     hits           우리 코드 실행량 -> 이 프레임이 무슨 일을 했는지 구분자
--     our_w          우리 글리프 자리에 쓴 word 수 · 주소범위 · 첫/마지막 줄
--     satb_w         SATB($1000-$10FF)에 쓴 word 수 · 슬롯 번호 목록
--     crosses        우리 쓰기 구간이 자막 띠를 가로지르는가
--     kind           idle / 전환추정 / 복원
--
-- ★ satb 슬롯 목록이 핵심이다
--     조각 2 가 9 칸인데 조각 1 이 16 칸이었다면, 전환에서 슬롯 9~15 를 **지워야**
--     한다.  안 지우면 앞 조각 글자가 남는다.
--     슬롯 번호를 그대로 찍으므로, 몇 번까지 건드리는지가 바로 보인다.
--
-- 판정
-- ---------------------------------------------------------------------------
--     전환 프레임에 satb 슬롯이 새 조각 칸수만큼만 쓰인다
--         ★ 남는 슬롯을 안 지운다 -- 증상 1 의 직접 원인
--     전환 프레임에 슬롯이 19 개(또는 이전 칸수)까지 쓰인다
--         지우기는 한다 -> 그럼 타이밍 문제다 (crosses 를 볼 것)
--     our_w 가 자막 띠를 가로지른다
--         업로드 중인 자리를 그리는 프레임이 있다
--
-- ⚠ 이 판은 문턱이 없어 행이 많다.  로그는 "뭔가 한" 프레임만 찍고,
--   TSV 에는 전부 남긴다.  idle 은 양쪽 다 뺀다.
--
-- ★ 화면에 아무것도 안 그린다.  게임을 한 바이트도 안 고친다.  개입 없음.
--
--   BIOS  build/patch/0.4.6.68/Syscard3_galmuri_0.4.6.68.pce
--   CUE   build/patch/0.4.6.68/Snatcher CD-ROMantic (Japan) [KO].cue
--   Power Cycle -> 이 파일만 로드 -> **조각이 2 개 이상인 대사**를 흘린다
--   ★ ADPCM_003078_6800_0E ('금일부로 JUNKER로 임명된' / '길리언 시드다만.') 가 딱 2 조각
--
-- 산출물  C:/snatcher/dump/fragment_0_5_128_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local ENGINE_LO, ENGINE_HI = 0x5B80, 0x5E1F
local CTL_VRAM_LO, CTL_VRAM_HI = 0x5D34, 0x5D35
local STATE_ADDR = 0x7FDF

local REGION_WORDS = 1216
local SATB_LO, SATB_HI = 0x1000, 0x10FF
local BAND_LO, BAND_HI = 118, 145        -- 자막 띠(y=122 + 글리프 높이).  ★가정값
local IDLE_HITS = 40                     -- 이 이하는 상주 폴링(실측 27)
local BIG_HITS  = 4000
local SAMPLE_EVERY = 32

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/fragment_0_5_128_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tkind\tstate\tbase\thits\t'
       .. 'our_w\tour_lo\tour_hi\tour_first\tour_last\tcrosses\t'
       .. 'satb_w\tslots_n\tslots\n')

local function say(f, ...) emu.log(string.format(f, ...)) end
local function rd(a)
  local ok, v = pcall(emu.read, a, MEM)
  return (ok and type(v) == 'number') and v or -1
end

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

local selReg, mawr, incr, pendLo = 0, 0, 1, 0
local function incrFrom(hi) local s = (hi >> 3) & 0x03
  return (s == 0) and 1 or (s == 1) and 32 or (s == 2) and 64 or 128 end

local hits = 0
local ourN, ourLo, ourHi, ourFirst, ourLast = 0, -1, -1, -1, -1
local satbN, slotSeen = 0, {}
local regLo, regHi = -1, -1

-- ★ 구간 경계는 **쓰기 시점에 즉시** 잡는다.
--   0.5.121~123 이 직전 프레임 끝의 control block 을 써서 세 판 연속 죽은 값을 냈다.
local function ensureRegion()
  if regLo >= 0 then return end
  local b = (rd(CTL_VRAM_HI) << 8) | rd(CTL_VRAM_LO)
  if b > 0 then regLo, regHi = b, b + REGION_WORDS - 1 end
end

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
    ensureRegion()
    if a >= SATB_LO and a <= SATB_HI then
      satbN = satbN + 1
      slotSeen[(a - SATB_LO) // 4] = true
    elseif regLo >= 0 and a >= regLo and a <= regHi then
      ourN = ourN + 1
      if ourLo < 0 or a < ourLo then ourLo = a end
      if ourHi < 0 or a > ourHi then ourHi = a end
      if ourN == 1 or ourN % SAMPLE_EVERY == 0 then
        local l = scanline()
        if ourFirst < 0 then ourFirst = l end
        ourLast = l
      end
    end
    mawr = (mawr + incr) & 0xFFFF
  end
end, emu.callbackType.write, 0x0000, 0x0003, CPU, MEM)

emu.addMemoryCallback(function() hits = hits + 1 end,
  emu.callbackType.exec, ENGINE_LO, ENGINE_HI, CPU, MEM)

local function slotList()
  local t = {}
  for k in pairs(slotSeen) do t[#t + 1] = k end
  table.sort(t)
  local parts = {}
  for i = 1, math.min(#t, 24) do parts[#parts + 1] = tostring(t[i]) end
  if #t > 24 then parts[#parts + 1] = '...+' .. (#t - 24) end
  return #t, table.concat(parts, ',')
end

local frame, transitions = 0, 0

emu.addEventCallback(function()
  frame = frame + 1

  if hits > IDLE_HITS then
    local kind = (hits >= BIG_HITS) and '복원' or '전환추정'
    if kind == '전환추정' then transitions = transitions + 1 end

    local crosses = '-'
    if ourFirst >= 0 and ourLast >= 0 then
      local lo = math.min(ourFirst, ourLast)
      local hi = math.max(ourFirst, ourLast)
      crosses = (lo <= BAND_HI and hi >= BAND_LO) and 'YES' or 'no'
    end
    local nSlots, slots = slotList()

    out:write(string.format('%d\t%s\t%d\t%04X\t%d\t%d\t%04X\t%04X\t%d\t%d\t%s\t%d\t%d\t%s\n',
      frame, kind, rd(STATE_ADDR),
      (rd(CTL_VRAM_HI) << 8) | rd(CTL_VRAM_LO), hits,
      ourN, ourLo < 0 and 0 or ourLo, ourHi < 0 and 0 or ourHi,
      ourFirst, ourLast, crosses, satbN, nSlots, slots))
    out:flush()

    if kind == '전환추정' then
      say('전환? f%d hits=%d  글리프 %d word $%04X-$%04X line %d..%d 띠교차=%s',
          frame, hits, ourN, ourLo < 0 and 0 or ourLo, ourHi < 0 and 0 or ourHi,
          ourFirst, ourLast, crosses)
      say('        SATB %d word · 슬롯 %d 개 [%s]', satbN, nSlots, slots)
    end
  end

  hits = 0
  ourN, ourLo, ourHi, ourFirst, ourLast = 0, -1, -1, -1, -1
  satbN, slotSeen = 0, {}
  regLo, regHi = -1, -1
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:close()
  say('0.5.128 끝 -- 전환추정 %d 프레임 · 저장 %s', transitions, PATH)
  if transitions == 0 then
    say('0.5.128 ⚠ 전환을 못 봤다.  조각이 2 개 이상인 대사를 흘렸는지 볼 것.'
        .. ' 판정하지 말 것')
  end
  say('0.5.128 ⚠ 자막 띠(%d..%d)는 가정값이다.  교차 0 이어도 닫지 말고'
      .. ' our_first/our_last 원자료로 다시 볼 것', BAND_LO, BAND_HI)
end, emu.eventType.scriptEnded)

say('SUB 0.5.128-fragment-transition armed -- 순수 관측 · 게임 무수정 · 화면 무개입')
say('  ★ 문턱을 없앴다.  0.5.115~127 은 hits>=4000 으로 걸러 조각 전환을 전부 버렸다')
say('  볼 것 : SATB 슬롯 목록.  새 조각 칸수만큼만 쓰이면 남는 슬롯을 안 지우는 것이다')
say('  덤프 : ' .. PATH)
