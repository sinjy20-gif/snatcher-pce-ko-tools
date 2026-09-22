-- SUB 0.4.94 -- 자막 프레임에 게임의 래스터 분할이 건너뛰어지는지 센다 (쓰기 0 B)
--
-- 여기까지 죽은 가설
-- ---------------------------------------------------------------------------
--     전송량(한 글자 0.4.87)     떨림만 줄고 번쩍임은 그대로
--     VDC 래치 경합(재무장 0.4.89) 그대로
--     BAT 본체 침범(0.4.90)      국장실 BAT 는 0..$0FFF.  글리프는 $1600
--     BG 패턴 침범(0.4.91)       국장실에서 겹침 0/4096 (다른 장면에서는 165 를
--                                찍었으므로 검출 능력은 증명된 음성 결과다)
--
-- 즉 **쓰는 자리는 남의 자리가 아니다.**  남은 것은 "언제 쓰느냐" 다.
--
-- 왜 한 글자로 안 줄었나 -- 다시 읽기
-- ---------------------------------------------------------------------------
-- 한 글자 패치는 글리프 루프만 1 회로 줄인다.  엔진의 고정 비용은 조각마다
-- 그대로 돈다: entry · 색인 조회 · TAI 레코드 전송($3F B) · 팔레트 stage ·
-- SATB 푸시.  그리고 번쩍임은 "자막 시작 시점에 짧게", 조각당 한 번이다.
--
--     떨림    글자 수에 비례했다 (줄었다)     -> 루프
--     번쩍임  글자 수와 무관했다 (안 줄었다)  -> 고정 구간
--
-- 그러므로 IRQ 지연 가설이 죽은 게 아니라, 범인이 루프가 아니라 고정 구간이다.
--
-- 무엇을 재나
-- ---------------------------------------------------------------------------
-- 스내처는 그림 창을 래스터 분할로 나눈다.  분할 IRQ 가 프레임마다 스크롤
-- 레지스터를 다시 쓴다.  그 쓰기가 **자막 프레임에만 줄어들면** 분할이
-- 건너뛰어진 것이고, 그림 띠가 아래로 번지며 BAT 가 세로로 감겨
-- 타일맵 위쪽이 화면에 나온다.  증상과 정확히 같은 모양이다.
--
--     프레임마다   BXR($07) · BYR($08) · RCR($06) · CR($05) 쓰기 횟수를 센다
--     엔진 프레임  ENGINE+count_ok 가 실행된 프레임을 표시한다
--     기준선       엔진이 안 돈 최근 프레임들의 BYR 횟수 최빈값
--
-- 판정
--     엔진 프레임의 BYR 횟수 < 기준선   ★ 분할이 건너뛰어졌다.  원인 확정
--     같다                              분할은 멀쩡하다.  스크롤 경로가 아니다
--                                       -> 그때는 SATB/스프라이트 쪽을 본다
--
-- ★ base_samples 가 0 이거나 scans 가 0 이면 아무 판정도 하지 말 것.
--
-- Power Cycle 뒤 이 파일 하나만 로드한다.  국장실까지 가서 자막 몇 개를 흘린다.

dofile('C:/snatcher/lua/SUB/0.4.89-vdc-rearm.lua')

local info = rawget(_G, 'SUB_REARM_INFO')
local ENGINE_LO = info and info.engine_lo or 0x5B80
local COUNT_OK = ENGINE_LO + (info and info.offsets.count_ok or 118)

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/raster_split_0_4_94_' .. STAMP .. '.tsv'
local out = io.open(OUT, 'w')
if out then
  out:write('frame\tkind\tkey\tcr\trcr\tbxr\tbyr\tbyr_base\tbxr_base\tverdict\n')
end

local selReg = 0
local cnt = { [0x05] = 0, [0x06] = 0, [0x07] = 0, [0x08] = 0 }
local portHits = 0

emu.addMemoryCallback(function(address, value)
  local port = address & 3
  portHits = portHits + 1
  if port == 0 then
    selReg = (value or 0) & 0xFF
  elseif port == 2 then
    -- 레지스터당 "데이터 쓰기 시작" 한 번으로 센다 (lo 쓰기 기준).
    if cnt[selReg] then cnt[selReg] = cnt[selReg] + 1 end
  end
end, emu.callbackType.write, 0x0000, 0x0003, CPU, MEM)

-- 음성 키 (장면 식별자).  0.4.48 의 사슬을 반드시 다시 부른다.
local curKey = '-'
local prevLog = emu.log
emu.log = function(message, ...)
  local key = tostring(message):match('KEY #%d+ (%x+)')
  if key then curKey = key end
  return prevLog(message, ...)
end

local engineFrame = false
emu.addMemoryCallback(function() engineFrame = true end,
  emu.callbackType.exec, COUNT_OK, COUNT_OK, CPU, MEM)

-- 기준선: 엔진이 안 돈 프레임의 BYR/BXR 횟수 최빈값
local byrHist, bxrHist = {}, {}
local baseSamples = 0
local function bump(hist, v) hist[v] = (hist[v] or 0) + 1 end
local function mode(hist)
  local best, bestN = nil, -1
  for v, n in pairs(hist) do if n > bestN then best, bestN = v, n end end
  return best
end

local frame, scans, skips = 0, 0, 0
local lastLine = ''

emu.addEventCallback(function()
  frame = frame + 1
  local cr, rcr, bxr, byr = cnt[0x05], cnt[0x06], cnt[0x07], cnt[0x08]
  cnt[0x05], cnt[0x06], cnt[0x07], cnt[0x08] = 0, 0, 0, 0

  if not engineFrame then
    -- 조용한 프레임만 기준선에 넣는다.
    bump(byrHist, byr); bump(bxrHist, bxr)
    baseSamples = baseSamples + 1
  else
    engineFrame = false
    scans = scans + 1
    local byrBase, bxrBase = mode(byrHist), mode(bxrHist)
    local verdict = 'unknown'
    if baseSamples >= 60 and byrBase then
      if byr < byrBase or (bxrBase and bxr < bxrBase) then
        verdict = 'SPLIT-SKIPPED'
        skips = skips + 1
      else
        verdict = 'split-ok'
      end
    end
    prevLog(string.format(
      'SUB 0.4.94 %df · KEY %s · 이 프레임 BYR %d (기준 %s) · BXR %d (기준 %s) · ' ..
      'RCR %d · CR %d · %s',
      frame, curKey, byr, tostring(byrBase), bxr, tostring(bxrBase), rcr, cr,
      verdict == 'SPLIT-SKIPPED' and '★ 분할이 건너뛰어졌다' or verdict))
    if out then
      out:write(string.format('%d\tengine\t%s\t%d\t%d\t%d\t%d\t%s\t%s\t%s\n',
        frame, curKey, cr, rcr, bxr, byr, tostring(byrBase), tostring(bxrBase),
        verdict))
      out:flush()
    end
  end

  emu.drawString(4, 64, string.format(
    '0.4.94 engine:%d skip:%d · BYR기준 %s · 표본 %d · hits:%d',
    scans, skips, tostring(mode(byrHist)), baseSamples, portHits),
    skips > 0 and 0x4040FF or 0x80FF80, 0x000000)
end, emu.eventType.endFrame)

prevLog('SUB 0.4.94-raster-split-skip armed -- 자막 프레임의 스크롤 쓰기 횟수를 센다')
prevLog(string.format('  count_ok $%04X · BYR/BXR/RCR/CR 프레임당 횟수', COUNT_OK))
prevLog('  ★ 표본 60 미만이거나 engine:0 이면 판정하지 말 것')
prevLog('  로그: ' .. OUT)
