-- SUB 0.5.143 -- $224D(CDB_LBA)가 $F687 경로에서도 유효한가
--
-- ★ 순수 관측.  아무것도 안 고친다.  게임 무수정.
--
-- 왜 재나
-- ---------------------------------------------------------------------------
-- 0.5.142 가 원인을 확정했다: BIOS 에 ADPCM 재생 루틴이 둘이고, 64 KB 를 넘는
-- 음성은 `$F687` 에서 시작한다.  우리 LBA 포착 훅은 `$F5F5`(정상 셋업 루틴 안)
-- 에만 걸려 있어서 그 173 건은 감지조차 안 된다.
--
--     고치는 길   `$F687` 의 `STA $180D`(8D 0D 18, 정확히 3 B)도 훅한다
--     조건        훅이 슬롯에 싣는 LBA 는 `$224D`(CDB_LBA) 에서 온다:
--                     LDA $224D+i / STA $1A00
--                 그 변수가 `$F687` 경로에서도 **그 음성의 LBA** 여야 한다
--
-- ⚠ `$22A6/$22A7` 는 그 경로에서 직전 음성 값 그대로였다 (0.5.136·0.5.137·0.5.142).
--   `$224D` 도 같은 꼴이면 훅을 걸어도 **직전 음성 자막이 뜬다.**
--   이건 "A2 도 받아주자" 가 위험했던 것과 같은 함정이다.
--
-- 무엇을 적나
-- ---------------------------------------------------------------------------
--     $224D 3 B 가 바뀐 프레임을 전부 (상한 없음) · 그때의 PC
--     재생 시작 프레임 · 그때 $224D 값 · 길이 포화 여부
--     그 값이 디렉터리에 HIT 하는가 (게이트와 같은 이분 검색)
--
-- 판정
--     ★SAT 재생 때 $224D 가 003123 (그 음성의 LBA) 이고 HIT
--         -> ★ 훅 하나 더 거는 것으로 끝난다
--     ★SAT 때 $224D 가 직전 음성 값
--         -> LBA 를 어디서 얻을지부터 찾아야 한다.  훅만으로는 안 된다
--     $224D 가 아예 안 바뀐다
--         -> 그 변수는 이 경로와 무관하다
--
-- 산출물  C:/snatcher/dump/cdb_lba_var_0_5_143_<시각>.tsv

local CDB_LBA = 0x224D
local AC_DIR  = 0x1F2800
local STRIDE  = 9

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/cdb_lba_var_0_5_143_' .. STAMP .. '.tsv'

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local AC = emu.memType.pceArcadeCardRam

local out = io.open(PATH, 'w')
out:write('frame\tkind\tpc\tcdb_lba\tlen\tsat\tdir\tnote\n')
local function say(m) emu.log(m); print(m) end
local function rd(a) local ok,v = pcall(emu.read, a, MEM); return ok and v or 0 end
local function rdac(a) local ok,v = pcall(emu.read, a, AC); return ok and v or -1 end
local function num(s,k) local v = s and s[k]; return type(v)=='number' and v or 0 end
local function cdb()
  return ((rd(CDB_LBA) & 0xFF) << 16) | ((rd(CDB_LBA+1) & 0xFF) << 8) | (rd(CDB_LBA+2) & 0xFF)
end
local function acLba(a)
  local b0,b1,b2 = rdac(a), rdac(a+1), rdac(a+2)
  if b0 < 0 then return -1 end
  return (b0<<16)|(b1<<8)|b2
end

local PC_KEY = nil
local function pcNow()
  local ok, s = pcall(emu.getState)
  if not ok or not s then return -1 end
  if PC_KEY == nil then
    PC_KEY = false
    for _, k in ipairs({ 'cpu.pc', 'pc' }) do
      if type(s[k]) == 'number' then PC_KEY = k break end
    end
  end
  if PC_KEY == false then return -1 end
  local v = s[PC_KEY]
  return type(v) == 'number' and math.floor(v) or -1
end

-- 디렉터리 항목 수
local nEnt = 0
do
  local prev = -1
  while nEnt < 1200 do
    local v = acLba(AC_DIR + nEnt*STRIDE)
    if v < 0x001000 or v > 0xFFFFFF or v <= prev then break end
    prev = v; nEnt = nEnt + 1
  end
  say(('디렉터리 항목 %d 개'):format(nEnt))
end
local function dirFind(want)
  local lo, hi = 0, nEnt - 1
  while lo <= hi do
    local mid = (lo + hi) >> 1
    local v = acLba(AC_DIR + mid*STRIDE)
    if v == want then return mid end
    if v < want then lo = mid + 1 else hi = mid - 1 end
  end
  return nil
end

emu.addMemoryCallback(function(address, value)
  local pc = pcNow()
  out:write(('%d\tWRITE\t%04X\t\t\t\t\t$%04X <- %02X\n'):format(
    0, pc, address, (value or 0) & 0xFF))
end, emu.callbackType.write, CDB_LBA, CDB_LBA + 2, CPU, MEM)

local frame, playing, prev = 0, false, -1

local function onFrame()
  frame = frame + 1
  local v = cdb()
  if v ~= prev then
    out:write(('%d\tCDB\t\t%06X\t\t\t\t바뀜\n'):format(frame, v))
    prev = v
  end

  local ok, s = pcall(emu.getState)
  if not ok or not s then return end
  local isPlay = s['cdrom.adpcm.playing']
  if isPlay == nil then isPlay = s['cdrom.adpcm.isPlaying'] end
  isPlay = isPlay and true or false

  if isPlay and not playing then
    local len = num(s, 'cdrom.adpcm.adpcmLength')
    local sat = (len >= 0xFF00) and 'SAT' or ''
    local slot = dirFind(v)
    out:write(('%d\tPLAY\t\t%06X\t%04X\t%s\t%s\t재생 시작\n'):format(
      frame, v, len, sat, slot and ('HIT slot '..slot) or 'MISS'))
    say(('%s PLAY f%-6d  $224D=%06X  len=%04X  디렉터리 %s'):format(
      sat == '' and '     ' or '★SAT', frame, v, len,
      slot and ('HIT slot '..slot) or 'MISS'))
    out:flush()
  end
  playing = isPlay
end

emu.addEventCallback(onFrame, emu.eventType.endFrame)
emu.addEventCallback(function() out:close() end, emu.eventType.scriptEnded)
say('SUB 0.5.143-cdb-lba-var armed -- 순수 관측')
say('  ★ ★SAT 행의 $224D 가 그 음성의 LBA 인가, 직전 음성 것인가')
say('  ' .. PATH)
