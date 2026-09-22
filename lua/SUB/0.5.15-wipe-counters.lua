-- SUB 0.5.15 -- 헬퍼의 wipe 진단 카운터를 읽는다 (쓰기 0 B)
--
-- 무엇을 확인하나
-- ---------------------------------------------------------------------------
-- 0.4.6.17 의 헬퍼는 복원 직전에 SATB 를 훑어 우리 슬롯만 지운다.  주소를
-- 하드코딩하지 않고 **조건이 곧 가드**인 자기검증 방식이다.  그 훑기 결과를
-- control block 에 남긴다.
--
--     wipe_seen   비어 있지 않던 슬롯 수
--     wipe_done   실제로 지운 슬롯 수
--
-- 읽는 법
--     seen > 0, done > 0    정상.  그 장면에서 우리 슬롯을 찾아 지웠다
--     seen > 0, done = 0    SATB 는 맞는데 그 시점에 자막 슬롯이 없었다
--     seen = 0              ★ 그 주소가 SATB 가 아니다.
--                           shadow 가 필요한 장면을 실제로 찾은 것이다
--
-- 언제 읽나
-- ---------------------------------------------------------------------------
-- 복원이 끝나면 상주부가 렌더러를 $5B80 에 덮으므로 카운터가 사라진다.
-- 그래서 **wipe 루틴의 RTS 시점**에 읽는다.  그때가 값이 확정된 유일한 순간이다.
--
--     wipe RTS    $5C9A     (subtitle_vram_helper.json · offsets.wipe_sprites +106)
--     wipe_seen   $5D32     (control block +2)
--     wipe_done   $5D33     (control block +3)
--
-- ★ 주소는 헬퍼를 다시 구우면 바뀔 수 있다.  build/cutscene_subs/
--   subtitle_vram_helper.json 의 offsets 로 대조할 것.
-- ★ 훅 0 회면 판정하지 말 것 -- 디스크가 0.4.6.17 이 아니거나 주소가 다르다.
--
-- Power Cycle 뒤 이 파일 하나만 로드한다.  장면을 여러 곳 돌아다닌다.

assert(rawget(_G, 'SUB_FRAGMENT_FORCE_KEY') == nil and
       rawget(_G, 'SUB_FRAGMENT_FORCE_BASE') == nil,
       '재무장 엔진에서는 SUB_FRAGMENT_FORCE_KEY/BASE 를 쓸 수 없다')

dofile('C:/snatcher/lua/SUB/0.4.89-vdc-rearm.lua')

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local WIPE_RTS = 0x5C9A
local SEEN, DONE = 0x5D32, 0x5D33

local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/wipe_counters_0_5_15_' .. STAMP .. '.tsv'
local out = io.open(OUT, 'w')
if out then out:write('frame\tkey\tseen\tdone\tverdict\n') end

local curKey = '-'
local prevLog = emu.log
emu.log = function(message, ...)
  local key = tostring(message):match('KEY #%d+ (%x+)')
  if key then curKey = key end
  return prevLog(message, ...)
end

local frame, hits = 0, 0
local badScenes = 0
local hist = {}
local lastLine = '아직 없음'

emu.addMemoryCallback(function()
  hits = hits + 1
  local seen = emu.read(SEEN, MEM) or 0
  local done = emu.read(DONE, MEM) or 0
  local verdict
  if seen == 0 then
    verdict = 'SATB 아님'
    badScenes = badScenes + 1
  elseif done == 0 then
    verdict = '자막 슬롯 없음'
  else
    verdict = '정상'
  end

  local sig = string.format('%d|%d', seen, done)
  hist[sig] = (hist[sig] or 0) + 1
  lastLine = string.format('seen %d · done %d · %s', seen, done, verdict)

  -- 같은 조합은 처음 몇 번만 찍는다
  if hist[sig] <= 3 or seen == 0 then
    prevLog(string.format('SUB 0.5.15 %df · KEY %s · seen %d · done %d · %s',
                          frame, curKey, seen, done, verdict))
  end
  if out then
    out:write(string.format('%d\t%s\t%d\t%d\t%s\n', frame, curKey, seen, done, verdict))
    out:flush()
  end
end, emu.callbackType.exec, WIPE_RTS, WIPE_RTS, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  emu.drawString(4, 84, string.format('0.5.15 wipe %d회 · %s · SATB아님 %d',
                 hits, lastLine, badScenes),
                 (hits > 0 and badScenes == 0) and 0x80FF80 or 0x4040FF, 0x000000)
end, emu.eventType.endFrame)

prevLog(string.format(
  'SUB 0.5.15-wipe-counters armed -- $%04X 에서 seen($%04X)/done($%04X) 를 읽는다',
  WIPE_RTS, SEEN, DONE))
prevLog('  ★ 훅 0 회면 판정 불가 -- 디스크가 0.4.6.17 인지 확인할 것')
prevLog('  ★ seen = 0 이 나오면 그 장면이 shadow 가 필요한 경우다')
prevLog('  로그: ' .. OUT)
