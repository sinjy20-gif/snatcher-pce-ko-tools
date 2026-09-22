-- SUB 0.5.123 -- 복원 청크 카운터 $15 가 도중에 바뀌는지 본다 (쓰기 0 B)
--
-- 무엇이 안 맞나
-- ---------------------------------------------------------------------------
-- 0.5.122 실측 (같은 값이 3 회 반복):
--
--     MAWR 설정   6600@66     단 한 번.  거기서부터 연속
--     쓰기        1,472 회 · $6600-$6BBF · line 71..248
--
-- 배포된 헬퍼 바이너리를 직접 읽으면:
--
--     off 155  LDA #$13 (19) / STA $15      19 청크
--     off 172  TIA $5CB0 -> $0002  len 128  청크당 128 B = 64 word
--     off 179  DEC $15
--
-- 19 x 64 = 1,216 word 여야 한다.  1,472 = 23 x 64 이다.  **루프가 23 번 돌았다.**
-- MAWR 은 한 번만 잡혔으니 그림자 드리프트가 아니다.
--
-- 왜 $15 를 의심하나
-- ---------------------------------------------------------------------------
-- 청크 카운터는 제로페이지 $15 다.  그런데 그건 우리 전용이 아니다:
--
--     "렌더러가 원래부터 작업용으로 쓰는 $15/$16 을 조회 중에도 빌린다"
--         -- tools/build_subtitle_engine_ac_record_poc.py
--
-- 그리고 이 루프는 **155 줄** 동안 돈다 (0.5.116).  그 사이 게임 IRQ 가 돈다.
-- 제로페이지는 게임 것이다.
--
-- ★ 이 판은 기구를 세우지 않는다.  $15 에 쓰인 값의 **수열**만 본다.
--
-- 어떻게 -- 값의 수열을 그대로 남긴다
-- ---------------------------------------------------------------------------
-- 우리 루프가 깨끗하면 수열은 이렇게 내려가기만 한다:
--
--     19(초기) 18 17 16 ... 3 2 1 0
--
-- 누가 끼어들면 **중간에 올라간다.**  올라간 자리와 값이 곧 범인의 지문이다.
--
--     ...  7 6 5  [12]  11 10 ...      <- 12 를 쓴 놈이 있다
--
-- ★ 제로페이지 주소에 대하여
--     HuC6280 의 제로페이지 주소지정은 논리주소 $2000-$20FF 를 친다 (MPR1).
--     그래서 `STA $15` 는 **논리 $2015** 다.  거기를 본다.
--     ⚠ 혹시 몰라 $0015 도 같이 센다.  $2015 가 0 이고 $0015 가 잡히면
--       매핑 가정이 틀린 것이므로, **그때는 아무 판정도 하지 말 것.**
--       둘 다 0 이면 "안 바뀐다" 가 아니라 "못 봤다" 다.
--
-- 읽는 법
-- ---------------------------------------------------------------------------
--     수열이 19 부터 단조감소            $15 는 안 건드려진다
--                                        -> 23 청크의 원인은 다른 데 있다 (닫지 말 것)
--     수열이 중간에 올라간다             ★ 카운터가 덮인다.  올라간 값과 줄이 증거
--     쓰기 수가 23~24 개                 루프가 23 번 돈 것과 일치
--     쓰기 수가 19~20 개인데 1,472 word  ★ 카운터는 멀쩡한데 청크가 더 크다
--                                        -> TIA 길이나 다른 경로를 봐야 한다
--
-- ★ 화면에 아무것도 안 그린다.  게임을 한 바이트도 안 고친다.
--
--   BIOS  build/patch/0.4.6.68/Syscard3_galmuri_0.4.6.68.pce
--   CUE   build/patch/0.4.6.68/Snatcher CD-ROMantic (Japan) [KO].cue
--   Power Cycle -> 이 파일만 로드 -> 0.5.122 와 같은 장면, 대사를 끝까지
--
-- 산출물  C:/snatcher/dump/chunk_counter_0_5_123_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local ENGINE_LO, ENGINE_HI = 0x5B80, 0x5E1F
local CTL_VRAM_LO, CTL_VRAM_HI = 0x5D34, 0x5D35
local STATE_ADDR = 0x7FDF

local ZP15   = 0x2015          -- HuC6280 제로페이지 $15 의 논리주소
local ZP15_ALT = 0x0015        -- 매핑 가정 검증용
local REGION_WORDS = 1216
local BIG_HITS = 4000
local MAX_LOG = 200

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/chunk_counter_0_5_123_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tstate\tbase\texec_hits\tzp15_writes\tzp15_alt\t'
       .. 'vram_words\trose_n\tverdict\tsequence\n')

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

local hits = 0
local seq, seqN, altN = {}, 0, 0
local vramWords = 0
local selReg, mawr, incr, pendLo = 0, 0, 1, 0
local regLo, regHi = -1, -1

local function incrFrom(hi) local s=(hi>>3)&0x03
  return (s==0) and 1 or (s==1) and 32 or (s==2) and 64 or 128 end

-- VRAM 쓰기 수 (우리 자리 근방만) -- 청크 수와 대조하기 위한 값
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
    if regLo >= 0 and a >= regLo and a < regLo + REGION_WORDS * 2 then
      vramWords = vramWords + 1
    end
    mawr = (mawr + incr) & 0xFFFF
  end
end, emu.callbackType.write, 0x0000, 0x0003, CPU, MEM)

emu.addMemoryCallback(function(address, value)
  seqN = seqN + 1
  if #seq < MAX_LOG then
    seq[#seq + 1] = string.format('%d@%d', (value or -1) & 0xFF, scanline())
  end
end, emu.callbackType.write, ZP15, ZP15, CPU, MEM)

emu.addMemoryCallback(function() altN = altN + 1 end,
  emu.callbackType.write, ZP15_ALT, ZP15_ALT, CPU, MEM)

emu.addMemoryCallback(function() hits = hits + 1 end,
  emu.callbackType.exec, ENGINE_LO, ENGINE_HI, CPU, MEM)

local frame, restores = 0, 0

emu.addEventCallback(function()
  frame = frame + 1

  if hits >= BIG_HITS then
    restores = restores + 1
    local base = (rd(CTL_VRAM_HI) << 8) | rd(CTL_VRAM_LO)

    -- 수열이 중간에 올라간 횟수
    local rose, prev = 0, nil
    for _, s in ipairs(seq) do
      local v = tonumber(s:match('^(%d+)@'))
      if prev and v and v > prev then rose = rose + 1 end
      prev = v
    end

    local verdict
    if seqN == 0 and altN == 0 then
      verdict = '★못봄(주소가정-의심)'
    elseif seqN == 0 and altN > 0 then
      verdict = '★$0015쪽이다(가정틀림)'
    elseif rose > 0 then
      verdict = '★카운터가-덮인다'
    else
      verdict = '단조감소(안덮인다)'
    end

    out:write(string.format('%d\t%d\t%04X\t%d\t%d\t%d\t%d\t%d\t%s\t%s\n',
      frame, rd(STATE_ADDR), base, hits, seqN, altN, vramWords, rose,
      verdict, table.concat(seq, ' ')))
    out:flush()

    say('0.5.123 f%d base=$%04X  $2015 쓰기 %d회 · $0015 %d회 · VRAM %d word'
        .. ' · 상승 %d회  [%s]',
        frame, base, seqN, altN, vramWords, rose, verdict)
    say('           수열: %s', table.concat(seq, ' '))
  end

  local b = (rd(CTL_VRAM_HI) << 8) | rd(CTL_VRAM_LO)
  if b > 0 then regLo, regHi = b, b + REGION_WORDS - 1 else regLo, regHi = -1, -1 end
  hits, seqN, altN, vramWords, seq = 0, 0, 0, 0, {}
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:close()
  say('0.5.123 끝 -- 복원 %d 회', restores)
  if restores == 0 then say('0.5.123 ⚠ 복원을 못 봤다.  판정하지 말 것') end
  say('0.5.123 ⚠ $2015 와 $0015 가 둘 다 0 이면 "안 바뀐다" 가 아니라 "못 봤다" 다')
  say('0.5.123 저장 %s', PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.123-chunk-counter armed -- 순수 관측 · 게임 무수정 · 화면 무개입')
say('  묻는 것 : 복원 청크 카운터 $15 가 155 줄 도는 사이에 덮이는가')
say('  깨끗하면 19 18 17 ... 1 0 으로 내려가기만 한다.  올라가면 그 자리가 증거다')
say('  덤프 : ' .. PATH)
