-- CDDA_DRIFT 0.1.0 -- "시작 LBA + 경과 프레임"으로 CD-DA 위치를 맞출 수 있나
--
-- 왜 재나
-- -------
-- CD-DA 자막은 **재생 중인 섹터가 어느 구간에 드는가**로 고른다.
--
--     lba_from <= 현재섹터 <= lba_to        색인 646 항목 · 10 B · lba_from 정렬
--
-- Lua 는 `cdrom.audioPlayer.currentSector` 를 그냥 읽으면 되지만 **실기에는
-- 그런 게 없다.**  네이티브에서는 위치를 스스로 알아내야 한다.  제일 싼 방법이
-- 이것이다:
--
--     시작 섹터를 한 번 잡아두고, 프레임 수만 센다
--     CD-DA 는 75 섹터/초 · 화면은 60 프레임/초  ->  프레임당 1.25 섹터
--
-- 이 스크립트는 그 추정이 **실제와 얼마나 어긋나는지**만 잰다.  오차가 자막
-- 구간(보통 수백 섹터)보다 훨씬 작으면 네이티브로 그대로 옮기면 된다.
--
-- 읽는 법
-- -------
--     최대 오차가 ±수 섹터        간다.  케이브에서 프레임만 세면 된다
--     오차가 계속 벌어진다        배속·일시정지·시크가 끼는 것.  다른 수를 찾는다
--
-- 로그: dump/cdda_drift_<날짜>.tsv  (프레임마다 한 줄이 아니라 60 프레임마다)

local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/cdda_drift_' .. STAMP .. '.tsv'

-- 75 섹터/초 · PC엔진은 **59.826 Hz** 다 (60 이 아니다).
-- 08-28 실측: 1,429 섹터 / 1,140 프레임 = 1.2535  ->  75/59.826 = 1.25364 와 일치
local SECTORS_PER_FRAME = 75 / 59.826

local f = io.open(OUT, 'w')
if f then f:write('frame\tstart\tframes\tactual\tpredicted\tdrift\n') end

local playing, startSector, startFrame = false, nil, nil
local lastSector = -1
local prevIdle = -1
local samples, worst, lastLog = 0, 0, -999
local frames = 0

local function state()
  local ok, s = pcall(emu.getState)
  if ok and s then return s end
  return {}
end

-- 키 이름이 코어 판마다 다르다.  한 번만 찾아서 기억한다.
-- (08-20 기록: emu.getState() 는 평평한 키를 준다)
local SECTOR_KEY, PLAY_KEY
local function findKeys(s)
  if SECTOR_KEY then return end
  local cands = {'cdrom.audioPlayer.currentSector', 'cdrom.audio.currentSector',
                 'cdrom.scsi.sector', 'cdrom.currentSector'}
  for _, k in ipairs(cands) do
    if s[k] ~= nil then SECTOR_KEY = k; break end
  end
  if not SECTOR_KEY then
    for k, v in pairs(s) do
      if type(v) == 'number' and k:lower():find('sector') then SECTOR_KEY = k; break end
    end
  end
  for _, k in ipairs({'cdrom.audioPlayer.playing', 'cdrom.audio.playing'}) do
    if s[k] ~= nil then PLAY_KEY = k; break end
  end
  if SECTOR_KEY then
    emu.log('CDDA_DRIFT 섹터 키 = ' .. SECTOR_KEY ..
            ' · 재생 키 = ' .. tostring(PLAY_KEY))
  else
    local n = 0
    for k, v in pairs(s) do
      if k:lower():find('cd') and n < 25 then
        emu.log('  키 후보: ' .. k .. ' = ' .. tostring(v)); n = n + 1
      end
    end
  end
end

emu.addEventCallback(function()
  frames = frames + 1
  local s = state()
  findKeys(s)
  local cur = SECTOR_KEY and s[SECTOR_KEY]
  local on = PLAY_KEY and s[PLAY_KEY]
  -- 키 이름은 코어 판마다 다를 수 있다.  섹터가 앞으로 가면 재생 중으로 본다.
  if cur == nil then
    if frames % 600 == 0 then
      emu.log('CDDA_DRIFT: 섹터 키를 못 찾았다 -- 위 후보 목록 참고')
    end
    return
  end

  -- 트랙이 바뀌면 다시 시작한다.  `playing` 키가 없는 코어가 있어서
  -- 섹터가 뒤로 가거나 크게 건너뛰면 새 트랙으로 본다.
  if playing and startSector then
    local jumped = cur < startSector or math.abs(cur - lastSector) > 500
    if jumped then
      emu.log(string.format('CDDA_DRIFT 트랙 바뀜: %d -> %d · 직전 %d 표본 최대 오차 %d',
                            lastSector, cur, samples, worst))
      playing, startSector, startFrame = false, nil, nil
      samples, worst = 0, 0
      prevIdle = cur
    end
  end
  lastSector = cur

  if not playing then
    -- ⚠ 멈춰 있어도 currentSector 에는 **직전 값이 남아 있다** (08-28 실측:
    --   스크립트를 켜자마자 212154 로 시작했다가 어긋났다).
    --   `playing` 키가 없는 코어가 있으므로, 섹터가 **실제로 앞으로 움직일 때**
    --   에만 기준점을 잡는다.
    if on == true or (prevIdle >= 0 and cur > prevIdle and cur - prevIdle < 10) then
      playing, startSector, startFrame = true, prevIdle, frames - 1
      samples, worst = 0, 0
      emu.log(string.format('CDDA_DRIFT 시작: 섹터 %d (프레임 %d)', startSector, startFrame))
    end
    prevIdle = cur
    return
  end

  -- 멈췄나 (섹터가 한동안 안 움직이면 끝난 것으로 본다)
  if on == false then
    emu.log(string.format('CDDA_DRIFT 끝: %d 표본 · 최대 오차 %d 섹터', samples, worst))
    playing, startSector, startFrame = false, nil, nil
    return
  end

  local elapsed = frames - startFrame
  local predicted = math.floor(startSector + elapsed * SECTORS_PER_FRAME + 0.5)
  local drift = cur - predicted
  if math.abs(drift) > math.abs(worst) then worst = drift end
  samples = samples + 1

  if frames - lastLog >= 60 then
    lastLog = frames
    if f then
      f:write(string.format('%d\t%d\t%d\t%d\t%d\t%d\n',
              frames, startSector, elapsed, cur, predicted, drift))
      f:flush()
    end
  end

  emu.drawString(4, 40, string.format('CDDA %d  예측 %d  오차 %+d (최대 %+d)',
                 cur, predicted, drift, worst),
                 (math.abs(worst) > 20) and 0xFF4040 or 0x40FF40, 0x000000)
end, emu.eventType.startFrame)

emu.log('CDDA_DRIFT 0.1.0 -- 시작섹터 + 프레임수 로 위치를 맞출 수 있는지 잰다')
emu.log(string.format('  75 섹터/초 · PC엔진 59.826 Hz -> 프레임당 %.5f 섹터',
                      SECTORS_PER_FRAME))
emu.log('  로그 ' .. OUT)
