-- SUB 0.5.141 -- AC 관측 슬롯을 프레임마다 본다.  왜 FFFF 만 실패하는가
--
-- ★ 순수 관측.  아무것도 안 고친다.  게임 무수정.
--
-- 왜 만드나 -- 소유자 지적
-- ---------------------------------------------------------------------------
-- "게이트가 LBA 만 본다면 왜 하필 FFFF 인 것만 실패하냐"  -- 맞는 지적이다.
-- 173/173 이 정확히 갈리는 것은 우연일 수 없는데, "슬롯이 A1 을 못 받는다" 는
-- 그 상관관계를 **설명하지 못한다.**  게다가 그 slot=A2 는 환경 A에서 잰 값이고
-- 이 빌드에서 직접 확인한 적이 없다.  그래서 슬롯을 직접 본다.
--
-- 슬롯 (build_snatcher_0_4_6_29_native_arm.py)
-- ---------------------------------------------------------------------------
--     AC_SLOT = $1F2700   11 B
--       +0   상태   $A1 = ST_FOUND(새 LBA 잡음) · $A2 = ST_CONSUMED(이미 씀)
--       +1~3 시작 LBA 3 B  -> armer 가 WANT 로 옮겨 디렉터리를 이분 검색한다
--     AC_DIR  = $1F2800   디렉터리 (LBA 3 + payload ptr 3 + VRAM 즉치 3)
--
-- 무엇을 적나
-- ---------------------------------------------------------------------------
--     SLOT   상태나 LBA 가 바뀐 프레임을 전부 (상한 없음)
--     PLAY   재생 시작 프레임 · 그때 슬롯 값 · 길이가 포화(FFFF)인가
--     CHECK  그 LBA 가 디렉터리에 실제로 있는가 -- Lua 가 직접 이분 검색한다
--
-- ★ CHECK 가 핵심이다.  슬롯 값으로 찾아지는지를 게이트와 같은 방식으로 재현한다
--     hit  -> 게이트도 찾을 수 있었다.  실패 원인은 다른 데 있다
--     miss -> 슬롯 LBA 가 디렉터리에 없다.  그 값이 무엇인지 바로 보인다
--
-- 산출물  C:/snatcher/dump/slot_watch_0_5_141_<시각>.tsv

local AC_SLOT = 0x1F2700
local AC_DIR  = 0x1F2800
local STRIDE  = 9

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/slot_watch_0_5_141_' .. STAMP .. '.tsv'
local AC = emu.memType.pceArcadeCardRam

local out = io.open(PATH, 'w')
out:write('frame\tkind\tstatus\tslot_lba\tlen\tsat\tdir_hit\tdir_near\tnote\n')
local function say(m) emu.log(m); print(m) end
local function rd(a) local ok, v = pcall(emu.read, a, AC); return ok and v or -1 end
local function lbaAt(a)
  local b0,b1,b2 = rd(a), rd(a+1), rd(a+2)
  if b0<0 then return -1 end
  return (b0<<16)|(b1<<8)|b2
end
local function num(s,k) local v = s and s[k]; return type(v)=='number' and v or 0 end

-- 디렉터리 항목 수를 한 번만 센다 (오름차순이 깨질 때까지)
local nEnt = 0
do
  local prev = -1
  while nEnt < 1200 do
    local v = lbaAt(AC_DIR + nEnt*STRIDE)
    if v < 0x001000 or v > 0xFFFFFF or v <= prev then break end
    prev = v; nEnt = nEnt + 1
  end
  say(('디렉터리 항목 %d 개 · %06X ~ %06X'):format(
    nEnt, lbaAt(AC_DIR), lbaAt(AC_DIR + (nEnt-1)*STRIDE)))
end

-- 게이트와 같은 방식으로 이분 검색한다
local function dirFind(want)
  local lo, hi = 0, nEnt - 1
  local near = -1
  while lo <= hi do
    local mid = (lo + hi) >> 1
    local v = lbaAt(AC_DIR + mid*STRIDE)
    if v == want then return mid, v end
    if v < want then near = v; lo = mid + 1 else hi = mid - 1 end
  end
  return nil, near
end

local frame, playing = 0, false
local pStat, pLba = -1, -1

local function onFrame()
  frame = frame + 1
  local stat, lba = rd(AC_SLOT), lbaAt(AC_SLOT + 1)

  if stat ~= pStat or lba ~= pLba then
    out:write(('%d\tSLOT\t%02X\t%06X\t\t\t\t\t%s\n'):format(
      frame, stat & 0xFF, lba & 0xFFFFFF,
      stat == 0xA1 and '★A1 새 LBA' or (stat == 0xA2 and 'A2 소비됨' or '')))
    if stat ~= pStat then
      say(('  SLOT f%-6d %02X  LBA=%06X  %s'):format(frame, stat & 0xFF, lba & 0xFFFFFF,
          stat == 0xA1 and '★A1' or (stat == 0xA2 and 'A2' or '')))
    end
    out:flush()
    pStat, pLba = stat, lba
  end

  local ok, s = pcall(emu.getState)
  if not ok or not s then return end
  local isPlay = s['cdrom.adpcm.playing']
  if isPlay == nil then isPlay = s['cdrom.adpcm.isPlaying'] end
  isPlay = isPlay and true or false

  if isPlay and not playing then
    local len = num(s, 'cdrom.adpcm.adpcmLength')
    local sat = (len >= 0xFF00) and 'SAT' or ''
    local slot, near = dirFind(lba)
    out:write(('%d\tPLAY\t%02X\t%06X\t%04X\t%s\t%s\t%06X\t\n'):format(
      frame, stat & 0xFF, lba & 0xFFFFFF, len, sat,
      slot and ('slot '..slot) or 'MISS', near & 0xFFFFFF))
    say(('%s PLAY f%-6d 슬롯 %02X LBA=%06X len=%04X  디렉터리 %s%s'):format(
      sat == '' and '     ' or '★SAT', frame, stat & 0xFF, lba & 0xFFFFFF, len,
      slot and ('HIT slot '..slot) or 'MISS',
      slot and '' or (' (직전값 %06X)'):format(near & 0xFFFFFF)))
    out:flush()
  end
  playing = isPlay
end

emu.addEventCallback(onFrame, emu.eventType.endFrame)
emu.addEventCallback(function() out:close() end, emu.eventType.scriptEnded)
say('SUB 0.5.141-slot-watch armed -- 순수 관측')
say('  ★ 볼 것: ★SAT 행에서 슬롯이 A1 인가, 그 LBA 가 디렉터리에 HIT 하는가')
say('  ' .. PATH)
