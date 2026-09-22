-- ★ HQ 2.5.0 -- CD-DA 재생 중에 ADPCM 이 무장하는가 (설계 §47-5 ④)
--
-- ⚠ 0.5.12 로 돌린다.  0.5.11 도 이 판정은 같은 자리라 돌아가지만, 기록은
--    0.5.12 기준으로 읽을 것.
--
-- 왜 이 판인가
-- ------------
-- CD-DA 전용 설계(§47~§49)의 마지막 미측정 항목이다.
--
--     새 설계에서 CD-DA 데이터 295 B 는 $5CF3-$5E19 에 산다.
--     ADPCM 렌더러 666 B 는 $5B80-$5E19 를 통째로 덮는다.
--     -> ★CD-DA 트랙 재생 중 ADPCM 이 무장하면 우리 데이터가 날아간다.
--
-- §47-8 에서 **트랙 3 한 판**은 확인했다 -- 무장(frame 8724) 이후 91 초 내내
-- ADPCM 무장이 0 회였다.  당연하기도 하다: CD-DA 컷신은 대사가 트랙 자체에
-- 실려 있어 ADPCM 음성을 안 쓴다.
--
-- 그런데 **트랙 4(73 줄) · 트랙 10(165 줄)** 은 안 쟀다.  그쪽이 겹치면
-- §49-5 의 "겹치면 다시 심는다" 코드가 실제로 필요해진다.
--
-- 어떻게 가르나
-- ------------
--   무장 순간 매체는 $5E1E 로 갈린다 (상주부의 렌더러 복사가 쓴다):
--       $CD -> CD-DA 렌더러      $FF -> ADPCM 렌더러
--   그래서 "$5E1E 가 CD 인 채 STATE=2 인 동안 START_SUB($FC7A)가 또 도는가" 만
--   보면 된다.
--
-- 쓰는 법
--     ① build/patch/0.5.12 로 Power Cycle
--     ② 이 파일 하나만 로드
--     ③ ★CD-DA 자막이 있는 트랙을 되도록 많이 지난다.
--        특히 트랙 4 · 트랙 10.  트랙 3(국장실)도 같이 지나면 대조가 된다
--     ④ 스크립트를 내리면 트랙별 표가 나온다
--
-- 산출  dump/hq_2_5_0_overlap_<시각>.tsv
--
-- 읽는 법
--     OVERLAP 행이 하나도 없다   -> ④ 는 일어나지 않는다.  재구성 코드가 필요 없다
--     OVERLAP 행이 있다          -> ★그 트랙에서 일어난다.  §49-5 코드가 필요하다
--                                   (설계가 무너지는 건 아니다 -- 캐시만 날아간다)
--
-- ⚠ 화면에 아무것도 안 그린다.  ⚠ 아무것도 안 쓴다 (읽기 전용).

local VERSION = '2.5.0'
local MEM = emu.memType.pceMemory

local STATE_AT = 0x7FDF
local CD_RAW   = 0x26F9
local MEDIA_AT = 0x5E1E        -- +670.  $CD = CD-DA · $FF = ADPCM
local MEDIA_CD = 0xCD
local START_SUB = 0xFC7A       -- 무장 진입 (매체 공통)

local stamp = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/hq_' .. VERSION:gsub('%.', '_')
            .. '_overlap_' .. stamp .. '.tsv'
local out = assert(io.open(OUT, 'w'))
out:write('frame\tevent\tstate\tcd_raw\tmedia\tdetail\n')

local function rb(at) return emu.read(at, MEM) or 0 end

local frame, rows = 0, 0
local cddaTrack = nil          -- 지금 CD-DA 로 무장한 트랙 (nil = 아님)
local cddaFrom = nil
local armsTotal, overlaps = 0, 0
local perTrack = {}            -- 트랙 -> {arms, overlap, frames}

local function line(ev, detail)
  rows = rows + 1
  out:write(string.format('%d\t%s\t%02X\t%02X\t%02X\t%s\n',
    frame, ev, rb(STATE_AT), rb(CD_RAW), rb(MEDIA_AT), detail or ''))
  out:flush()
end

local function slot(t)
  perTrack[t] = perTrack[t] or { arms = 0, overlap = 0, frames = 0 }
  return perTrack[t]
end

-- 무장 진입.  이 시점의 $5E1E 는 **직전 매체**다 (복사는 뒤에 온다)
emu.addMemoryCallback(function()
  armsTotal = armsTotal + 1
  if cddaTrack then
    overlaps = overlaps + 1
    slot(cddaTrack).overlap = slot(cddaTrack).overlap + 1
    line('★OVERLAP', string.format(
      'CD-DA 트랙 %02X 재생 중(%d 프레임째)에 무장이 또 들어왔다 -- 새 설계라면 데이터가 날아간다',
      cddaTrack, frame - (cddaFrom or frame)))
  end
end, emu.callbackType.exec, START_SUB, START_SUB, emu.cpuType.pce, MEM)

-- 매체가 정해지는 순간 = 상주부의 렌더러 복사가 $5E1E 를 쓴다
emu.addMemoryCallback(function(address, value)
  local was = rb(MEDIA_AT)
  if value == MEDIA_CD and was ~= MEDIA_CD then
    cddaTrack = rb(CD_RAW)
    cddaFrom = frame
    local s = slot(cddaTrack)
    s.arms = s.arms + 1
    line('CDDA_ARM', string.format('트랙 %02X 무장', cddaTrack))
  elseif value ~= MEDIA_CD and was == MEDIA_CD and cddaTrack then
    line('CDDA_GONE', string.format('트랙 %02X 매체 지문이 %02X 로 바뀌었다 (ADPCM 이 덮었다)',
      cddaTrack, value))
  end
end, emu.callbackType.write, MEDIA_AT, MEDIA_AT, emu.cpuType.pce, MEM)

-- STATE 가 0 으로 돌아오면 그 CD-DA 재생은 끝난 것으로 본다
emu.addMemoryCallback(function(address, value)
  local old = rb(STATE_AT)
  if old ~= value then
    if value == 0x00 and cddaTrack then
      line('CDDA_END', string.format('트랙 %02X 끝 (%d 프레임 = %.1f 초)',
        cddaTrack, frame - (cddaFrom or frame), (frame - (cddaFrom or frame)) / 60))
      cddaTrack, cddaFrom = nil, nil
    end
  end
end, emu.callbackType.write, STATE_AT, STATE_AT, emu.cpuType.pce, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  if cddaTrack then slot(cddaTrack).frames = slot(cddaTrack).frames + 1 end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  line('TOTALS', string.format('무장 %d 회 · ★겹침 %d 회 · 프레임 %d',
    armsTotal, overlaps, frame))
  local keys = {}
  for t in pairs(perTrack) do keys[#keys + 1] = t end
  table.sort(keys)
  for _, t in ipairs(keys) do
    local s = perTrack[t]
    line('TRACK', string.format('트랙 %02X  무장 %d · 재생 %d 프레임(%.1f초) · ★겹침 %d %s',
      t, s.arms, s.frames, s.frames / 60, s.overlap,
      (s.overlap > 0) and '<- 여기서 일어난다' or ''))
  end
  line('VERDICT', (overlaps > 0)
    and '★겹친다.  §49-5 의 "겹치면 다시 심는다" 코드가 필요하다'
    or  '이 주행에서는 안 겹친다.  지난 트랙 목록을 TRACK 행으로 확인할 것')
  out:close()
end, emu.eventType.scriptEnded)

emu.log('HQ ' .. VERSION .. ' ADPCM 겹침 -> ' .. OUT)
