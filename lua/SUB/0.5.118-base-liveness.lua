-- SUB 0.5.118 -- 우리가 빌린 VRAM 자리를 게임이 "표시에 쓰고 있는가" (쓰기 0 B)
--
-- 왜 이걸 재나
-- ---------------------------------------------------------------------------
-- 0.5.117 로 확정된 것:
--
--     복원 직전 SATB wipe 는 제대로 먹는다   seen 22~23 · done 7~9 · status 2
--     그런데도 복원 중 화면에 잔해가 보인다  (소유자 사진 2)
--
-- 지웠는데 보인다 -> 잔해는 **우리 스프라이트가 아니다.**
-- 남는 설명은 하나다: 복원이 155 줄에 걸쳐 base 를 되쓰는 동안,
-- **게임이 그 반쯤 복원된 영역을 그린다.**
--
-- 그런데 그렇다면 앞뒤가 안 맞는다.
--
--     base 가 정말 죽은 자리였다면, 반쯤 복원된 상태를 아무도 안 그려서
--     **안 보여야 한다.**  보인다는 것은 게임이 그 자리를 표시에 쓴다는 뜻이다.
--
-- "안전자리" 는 *게임이 거기 쓰는가* 로 골랐을 가능성이 크다.  그런데
-- **안 쓰는 것과 안 보는 것은 다르다.**  BG 가 참조만 해도 우리가 덮는 순간
-- 화면에 나온다.  이 판은 그 참조를 직접 센다.
--
-- 무엇을 세나
-- ---------------------------------------------------------------------------
--     BAT   각 엔트리의 타일 그림 구간이 우리 영역과 겹치는가
--             tile = entry & 0x07FF · 그림 = tile*16 word · 16 word 길이   (0.4.91)
--     SATB  각 슬롯의 pattern 이 우리 영역을 가리키는가
--             pattern 단위 = 32 word · 팔레트 하위 4 비트                  (헬퍼 wipe)
--             팔레트 $F = 우리 것 · 그 외 = 게임 것.  **나눠 센다**
--
-- 영역은 control block 에서 **동적으로** 잡는다.  base 는 키별로 다르다.
--
--     $5D34 VRAM_LO · $5D35 VRAM_HI  ->  base(word)
--     길이 1,216 word  ( = 19 글리프 x 2 패턴 x 32 word.  검산됨)
--
-- ★ 0.4.91 은 PAT_VRAM=0x1600 을 상수로 박았다.  지금 base 는 키별이고
--   실측값은 $6600 이다.  그대로 쓰면 엉뚱한 데를 본다 -- 그래서 이 판을 새로 짠다.
--
-- 판정
-- ---------------------------------------------------------------------------
--     bat_hits > 0                ★ 배경이 우리 자리를 그림으로 쓴다
--     satb_game > 0               ★ 게임 스프라이트가 우리 자리를 가리킨다
--        둘 중 하나라도 >0  ->  그 자리는 표시에 살아 있다.
--                               고칠 곳은 전송 타이밍이 아니라 **자리 선정**
--                               (tools/build_vram_key_bases.py)
--
--     둘 다 0                     빌린 자리는 맞다.  잔해의 출처를 다시 찾아야 한다
--        ⚠ 이 경우 "원인 없음" 으로 닫지 말 것.  이 프로브가 못 보는 경로가 남는다
--           (게임이 프레임 중간에 BAT/SATB 를 바꿔 쓰는 경우 · DMA · 팔레트 경유)
--           endFrame 한 시점만 보므로 프레임 내 변화는 안 잡힌다
--
--     satb_ours 는 참고값이다.  자막이 떠 있으면 >0 이 정상이고,
--     복원 직후 프레임에서 0 이면 wipe 가 먹은 것이다 (0.5.117 과 교차 검증)
--
-- 언제 스캔하나
-- ---------------------------------------------------------------------------
--     STATE != 0 (자막이 떠 있는 동안)  SCAN_EVERY 프레임마다
--     복원 프레임 (exec 히트 >= BIG_HITS)  무조건
--
-- BAT 전수 스캔은 최대 4,096 엔트리라 싸지 않다.  그래서 간격을 둔다.
--
-- ★ 화면에 아무것도 안 그린다 (0.4.91 은 drawString 을 쓴다.  이 판은 안 쓴다).
-- ★ 게임을 한 바이트도 안 고친다.  VRAM 읽기 전용.
--
--   BIOS  build/patch/0.4.6.68/Syscard3_galmuri_0.4.6.68.pce
--   CUE   build/patch/0.4.6.68/Snatcher CD-ROMantic (Japan) [KO].cue
--   Power Cycle -> 이 파일만 로드 -> 대사를 끝까지 흘린다 (0.5.117 과 같은 장면)
--
-- 산출물  C:/snatcher/dump/base_liveness_0_5_118_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local VRAM = emu.memType.pceVideoRam

local ENGINE_LO, ENGINE_HI = 0x5B80, 0x5E1F

local CTL_STATUS   = 0x5D31
local CTL_WIPE_SEEN= 0x5D32
local CTL_WIPE_DONE= 0x5D33
local CTL_VRAM_LO  = 0x5D34
local CTL_VRAM_HI  = 0x5D35
local STATE_ADDR   = 0x7FDF

local REGION_WORDS = 1216        -- 19 글리프 x 2 패턴 x 32 word
local TILE_WORDS   = 16          -- BG 타일 하나의 그림 데이터
local SPR_WORDS    = 32          -- 스프라이트 pattern 한 단위
local SATB_SLOTS   = 64
local GLYPH_PALETTE= 0x0F

local BIG_HITS   = 4000          -- 이 이상이면 복원 버스트 (실측 13,800)
local SCAN_EVERY = 30

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/base_liveness_0_5_118_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tkind\tstate\tstatus\tbase\treg_lo\treg_hi\t'
       .. 'bat_cols\tbat_rows\tbat_entries\tbat_hits\ttile_lo\ttile_hi\t'
       .. 'satb\tsatb_ours\tsatb_game\twipe_seen\twipe_done\tverdict\n')

local function say(f, ...) emu.log(string.format(f, ...)) end
local function rd(a)
  local ok, v = pcall(emu.read, a, MEM)
  return (ok and type(v) == 'number') and v or -1
end
local function rb(at)
  local ok, v = pcall(emu.read, at, VRAM)
  return (ok and type(v) == 'number') and v or 0
end
local function rw(word) local at = word * 2; return rb(at) | (rb(at + 1) << 8) end

-- VDC 레지스터 추적 (0.4.91 과 같은 방식)
local selReg, mwrReg, dvssr = 0, nil, nil
emu.addMemoryCallback(function(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF
  if port == 0 then
    selReg = value
  elseif port == 2 then
    if selReg == 0x09 then mwrReg = value
    elseif selReg == 0x13 then dvssr = ((dvssr or 0) & 0xFF00) | value end
  elseif port == 3 then
    if selReg == 0x13 then dvssr = ((dvssr or 0) & 0x00FF) | (value << 8) end
  end
end, emu.callbackType.write, 0x0000, 0x0003, CPU, MEM)

local function dimensions()
  if mwrReg then
    local w = (mwrReg >> 4) & 0x03
    local columns = (w == 0) and 32 or (w == 1) and 64 or 128
    local rows = (((mwrReg >> 6) & 1) == 1) and 64 or 32
    return columns, rows
  end
  local ok, s = pcall(emu.getState)
  if ok and s then
    local c, r = s['vdc.hvReg.columnCount'], s['vdc.hvReg.rowCount']
    if type(c) == 'number' and type(r) == 'number' then
      return math.floor(c), math.floor(r)
    end
  end
  return 0, 0
end

local function satbAddress()
  if dvssr then return dvssr & 0x7FFF end
  return -1
end

-- 우리 코드 실행량 (복원 프레임 판별용)
local hits = 0
emu.addMemoryCallback(function() hits = hits + 1 end,
  emu.callbackType.exec, ENGINE_LO, ENGINE_HI, CPU, MEM)

local frame, scans, liveFrames = 0, 0, 0

local function scanBat(lo, hi)
  local columns, rows = dimensions()
  local entries = columns * rows
  local hitCount, tileLo, tileHi = 0, nil, nil
  if entries == 0 then return columns, rows, 0, 0, -1, -1 end
  for i = 0, entries - 1 do
    local tile = rw(i) & 0x07FF
    local first = tile * TILE_WORDS
    local lastw = first + TILE_WORDS - 1
    if tileLo == nil or first < tileLo then tileLo = first end
    if tileHi == nil or lastw > tileHi then tileHi = lastw end
    if lastw >= lo and first <= hi then hitCount = hitCount + 1 end
  end
  return columns, rows, entries, hitCount, tileLo or -1, tileHi or -1
end

local function scanSatb(lo, hi)
  local satb = satbAddress()
  if satb < 0 then return -1, -1, -1 end
  local ours, game = 0, 0
  for i = 0, SATB_SLOTS - 1 do
    local pattern = rw(satb + i * 4 + 2)
    local attr    = rw(satb + i * 4 + 3)
    if pattern ~= 0 then
      local first = (pattern & 0x07FF) * SPR_WORDS
      local lastw = first + SPR_WORDS - 1
      if lastw >= lo and first <= hi then
        if (attr & 0x0F) == GLYPH_PALETTE then ours = ours + 1 else game = game + 1 end
      end
    end
  end
  return satb, ours, game
end

emu.addEventCallback(function()
  frame = frame + 1
  local state = rd(STATE_ADDR)
  local isRestore = hits >= BIG_HITS
  local want = isRestore or (state ~= 0 and frame % SCAN_EVERY == 0)

  if want then
    local base = (rd(CTL_VRAM_HI) << 8) | rd(CTL_VRAM_LO)
    if base > 0 then
      local lo = base
      local hi = base + REGION_WORDS - 1
      local cols, rows, entries, batHits, tLo, tHi = scanBat(lo, hi)
      local satb, sOurs, sGame = scanSatb(lo, hi)

      local live = (batHits > 0) or (sGame > 0)
      local verdict = (entries == 0) and 'unknown'
                      or (live and '★자리가-살아있다' or '자리-조용함')
      if live then liveFrames = liveFrames + 1 end
      scans = scans + 1

      out:write(string.format(
        '%d\t%s\t%d\t%d\t%04X\t%04X\t%04X\t%d\t%d\t%d\t%d\t%d\t%d\t%04X\t%d\t%d\t%d\t%d\t%s\n',
        frame, isRestore and '복원' or '자막중', state, rd(CTL_STATUS),
        base, lo, hi, cols, rows, entries, batHits, tLo, tHi,
        satb < 0 and 0 or satb, sOurs, sGame,
        rd(CTL_WIPE_SEEN), rd(CTL_WIPE_DONE), verdict))
      out:flush()

      if isRestore or live then
        say('0.5.118 f%d %s base=$%04X 영역 $%04X-$%04X  BAT %dx%d %d/%d 겹침'
            .. '  배경타일 $%04X-$%04X  SATB $%04X 우리%d 게임%d  %s',
            frame, isRestore and '복원' or '자막중', base, lo, hi,
            cols, rows, batHits, entries, tLo, tHi,
            satb < 0 and 0 or satb, sOurs, sGame, verdict)
      end
    end
  end
  hits = 0
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:close()
  say('0.5.118 끝 -- 스캔 %d 회 · 자리가 살아있던 프레임 %d', scans, liveFrames)
  if scans == 0 then
    say('0.5.118 ⚠ 한 번도 스캔 못 했다.  자막을 안 띄웠거나 control block base 가 0 이다.'
        .. ' 아무 판정도 하지 말 것')
  elseif liveFrames == 0 then
    say('0.5.118 ⚠ 겹침 0 이다.  단 이것으로 "원인 없음" 을 닫지 말 것 --'
        .. ' endFrame 한 시점만 보므로 프레임 내 BAT/SATB 변화는 안 잡힌다')
  end
  say('0.5.118 저장 %s', PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.118-base-liveness armed -- 순수 관측 · 게임 무수정 · 화면 무개입')
say('  묻는 것 : 우리가 빌린 자리를 게임 BAT/SATB 가 참조하는가')
say('  영역은 control block($5D34/$5D35)에서 동적으로 잡는다 (base 는 키별)')
say('  덤프 : ' .. PATH)
