-- SUB 0.5.119 -- 복원 중 VRAM 쓰기가 **실제로 어디로 가는지** 지도로 뜬다 (쓰기 0 B)
--
-- 왜 이걸 재나
-- ---------------------------------------------------------------------------
-- 0.5.118 이 이상한 것을 남겼다.
--
--     BAT 가 참조하는 곳   $1100-$2BBF
--     우리가 되쓰는 곳     $6600-$6ABF        (control block 이 말하는 base)
--     겹침                 0 / 4096 엔트리
--     SATB                 우리 0 · 게임 0
--
-- 아무도 안 보는 자리에 쓰는데 화면은 깨진다 (소유자 사진 2).  둘 중 하나다.
--
--     (ㄱ) 쓰기가 우리가 믿는 곳으로 안 간다
--          -- 복원 155 줄 사이에 게임 IRQ 가 끼어들어 MAWR 을 옮기면,
--             남은 청크가 게임 주소로 쏟아진다
--     (ㄴ) 복원 중에 **다른 누군가**가 산 자리($1100-$2BBF)에 쓴다
--
-- 둘 다 "쓰기의 목적지 주소" 를 알면 갈린다.  그래서 그것을 직접 복원한다.
--
-- 어떻게 -- 포트만 보고 주소를 되살린다
-- ---------------------------------------------------------------------------
-- VDC 는 포트 넷뿐이다.  MAWR 을 그림자로 들고 자동증가를 따라가면
-- **모든 VRAM 쓰기의 목적지**가 나온다.  getState 를 한 번도 안 부른다 (싸다).
--
--     port0 <- v            레지스터 선택 (selReg)
--     port2 <- v  sel=$00   MAWR 하위
--     port3 <- v  sel=$00   MAWR 상위
--     port2 <- v  sel=$02   VWR 하위 (아직 안 쓴다)
--     port3 <- v  sel=$02   VWR 상위 -> ★이때 VRAM 에 워드가 쓰이고 MAWR 이 증가
--     port2 <- v  sel=$05   CR 하위 -> 증가폭 비트 (11,12)
--
-- 증가폭은 CR 에서 읽되 못 보면 +1 로 본다 (기본값).  ⚠ 이 가정은 로그에 찍는다.
--
-- 무엇을 세나 -- 복원 프레임의 쓰기를 목적지로 분류
-- ---------------------------------------------------------------------------
--     our     [base, base+1216)      우리가 되쓴다고 믿는 자리
--     bg      $1100-$2BBF            0.5.118 이 잰, 이 장면 BG 가 참조하는 자리
--     satb    $1000-$10FF            스프라이트 표
--     bat     $0000-$0FFF            타일맵 본체
--     other   그 외                  min/max 를 같이 찍는다
--
-- 판정
-- ---------------------------------------------------------------------------
--     our ≈ 1216 · other ≈ 0        복원은 믿는 곳으로 간다.  (ㄱ) 기각
--                                    -> 잔해 출처는 여기가 아니다.  (ㄴ) 나 다른 것
--     our << 1216 이고 other 큼      ★ MAWR 이 중간에 옮겨졌다.  (ㄱ) 성립
--                                    -> other_min/max 가 어디로 샜는지 말해준다
--     bg > 0                         ★ 복원 중 산 자리에 쓰고 있다.  (ㄴ) 성립
--                                    -> 그 쓰기가 우리 것인지 게임 것인지 다음에 가른다
--
--     ⚠ our 가 1216 을 **넘으면** 게임 쓰기까지 우리 구간에 섞인 것이다.
--       그 자체가 "그 자리는 죽지 않았다" 는 증거다.  0 이 아니라 초과도 볼 것.
--
-- ⚠ 이 판이 못 보는 것
--     DMA(SATB 전송·VRAM-VRAM)는 포트를 안 거치므로 안 잡힌다.
--     그러니 "쓰기 0" 을 "아무 일도 없었다" 로 읽지 말 것.
--
-- ★ 화면에 아무것도 안 그린다.  게임을 한 바이트도 안 고친다.
--
--   BIOS  build/patch/0.4.6.68/Syscard3_galmuri_0.4.6.68.pce
--   CUE   build/patch/0.4.6.68/Snatcher CD-ROMantic (Japan) [KO].cue
--   Power Cycle -> 이 파일만 로드 -> 0.5.117/118 과 같은 장면, 대사를 끝까지
--
-- 산출물  C:/snatcher/dump/vram_write_map_0_5_119_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local ENGINE_LO, ENGINE_HI = 0x5B80, 0x5E1F
local CTL_VRAM_LO, CTL_VRAM_HI = 0x5D34, 0x5D35
local STATE_ADDR = 0x7FDF

local REGION_WORDS = 1216
local BG_LO, BG_HI     = 0x1100, 0x2BBF     -- 0.5.118 실측 (이 장면)
local SATB_LO, SATB_HI = 0x1000, 0x10FF
local BAT_LO, BAT_HI   = 0x0000, 0x0FFF

local BIG_HITS = 4000

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/vram_write_map_0_5_119_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tkind\tstate\tbase\texec_hits\tvram_writes\t'
       .. 'our\tbg\tsatb\tbat\tother\tother_min\tother_max\tmawr_sets\tincr\tverdict\n')

local function say(f, ...) emu.log(string.format(f, ...)) end
local function rd(a)
  local ok, v = pcall(emu.read, a, MEM)
  return (ok and type(v) == 'number') and v or -1
end

-- VDC 그림자
local selReg, mawr, incr = 0, 0, 1
local crLo = nil

-- 프레임 집계
local hits, writes = 0, 0
local cOur, cBg, cSatb, cBat, cOther = 0, 0, 0, 0, 0
local oMin, oMax, mawrSets = -1, -1, 0

-- 분류 경계는 프레임마다 control block 에서 새로 잡는다
local regLo, regHi = -1, -1

local function classify(addr)
  if regLo >= 0 and addr >= regLo and addr <= regHi then
    cOur = cOur + 1
  elseif addr >= BG_LO and addr <= BG_HI then
    cBg = cBg + 1
  elseif addr >= SATB_LO and addr <= SATB_HI then
    cSatb = cSatb + 1
  elseif addr >= BAT_LO and addr <= BAT_HI then
    cBat = cBat + 1
  else
    cOther = cOther + 1
    if oMin < 0 or addr < oMin then oMin = addr end
    if oMax < 0 or addr > oMax then oMax = addr end
  end
end

emu.addMemoryCallback(function(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF
  if port == 0 then
    selReg = value
  elseif port == 2 then
    if selReg == 0x00 then
      mawr = (mawr & 0xFF00) | value
    elseif selReg == 0x05 then
      crLo = value
    end
  elseif port == 3 then
    if selReg == 0x00 then
      mawr = (mawr & 0x00FF) | (value << 8)
      mawrSets = mawrSets + 1
    elseif selReg == 0x02 then
      -- VWR 상위 기입 -> 워드 하나가 VRAM 에 들어가고 주소가 증가한다
      writes = writes + 1
      classify(mawr & 0x7FFF)
      mawr = (mawr + incr) & 0xFFFF
    end
  end
end, emu.callbackType.write, 0x0000, 0x0003, CPU, MEM)

emu.addMemoryCallback(function() hits = hits + 1 end,
  emu.callbackType.exec, ENGINE_LO, ENGINE_HI, CPU, MEM)

-- CR 의 증가폭 비트 (11,12) -> 1 / 32 / 64 / 128
local function incrFromCr()
  if crLo == nil then return 1 end
  local sel = (crLo >> 3) & 0x03           -- CR bit 11,12 는 하위바이트 bit 3,4
  return (sel == 0) and 1 or (sel == 1) and 32 or (sel == 2) and 64 or 128
end

local frame, restores, badFrames = 0, 0, 0

emu.addEventCallback(function()
  frame = frame + 1
  incr = incrFromCr()

  local isRestore = hits >= BIG_HITS
  if isRestore then
    restores = restores + 1
    local base = (rd(CTL_VRAM_HI) << 8) | rd(CTL_VRAM_LO)
    local verdict
    if cBg > 0 then
      verdict = '★산자리에-쓴다'
    elseif cOur > REGION_WORDS then
      verdict = '★우리구간에-남의쓰기'
    elseif cOur < REGION_WORDS // 2 then
      verdict = '★믿는곳으로-안간다'
    else
      verdict = '믿는곳으로-간다'
    end
    if verdict ~= '믿는곳으로-간다' then badFrames = badFrames + 1 end

    out:write(string.format(
      '%d\t%s\t%d\t%04X\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%04X\t%04X\t%d\t%d\t%s\n',
      frame, '복원', rd(STATE_ADDR), base, hits, writes,
      cOur, cBg, cSatb, cBat, cOther,
      oMin < 0 and 0 or oMin, oMax < 0 and 0 or oMax, mawrSets, incr, verdict))
    out:flush()

    say('0.5.119 f%d 복원 base=$%04X 쓰기 %d  our=%d bg=%d satb=%d bat=%d other=%d'
        .. ' (%04X-%04X)  MAWR설정 %d회  incr=+%d  %s',
        frame, base, writes, cOur, cBg, cSatb, cBat, cOther,
        oMin < 0 and 0 or oMin, oMax < 0 and 0 or oMax, mawrSets, incr, verdict)
  end

  -- 다음 프레임 준비.  구간 경계는 지금 control block 값으로 잡아둔다
  local b = (rd(CTL_VRAM_HI) << 8) | rd(CTL_VRAM_LO)
  if b > 0 then regLo, regHi = b, b + REGION_WORDS - 1 else regLo, regHi = -1, -1 end
  hits, writes = 0, 0
  cOur, cBg, cSatb, cBat, cOther = 0, 0, 0, 0, 0
  oMin, oMax, mawrSets = -1, -1, 0
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:close()
  say('0.5.119 끝 -- 복원 %d 회 · 이상 %d 회', restores, badFrames)
  if restores == 0 then
    say('0.5.119 ⚠ 복원을 못 봤다.  대사를 끝까지 안 흘렸다.  판정하지 말 것')
  end
  say('0.5.119 ⚠ DMA(SATB 전송 등)는 포트를 안 거쳐 안 잡힌다.'
      .. ' "쓰기 0" 을 "아무 일 없었다" 로 읽지 말 것')
  say('0.5.119 저장 %s', PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.119-vram-write-map armed -- 순수 관측 · 게임 무수정 · 화면 무개입')
say('  MAWR 그림자로 모든 VRAM 쓰기의 목적지를 되살려 구간별로 센다 (getState 미사용)')
say('  묻는 것 : 복원의 쓰기가 정말 base 로 가는가 · 산 자리($1100-$2BBF)에 쓰는가')
say('  덤프 : ' .. PATH)
