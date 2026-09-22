-- SUB 0.4.95 -- IRQ 한 회차 손실이 우리 탓인가, 게임 원래 그런가 (쓰기 0 B)
--
-- 0.4.94 가 찾은 신호
-- ---------------------------------------------------------------------------
--     음성의 첫 조각 프레임   BYR 3 · BXR 3 · RCR 2 · CR 0
--     그 뒤 조각 프레임       BYR 4 · BXR 4 · RCR 3 · CR 1   (기준선과 같다)
--
-- BYR 하나만 준 게 아니라 BXR·RCR·CR 이 같이 하나씩 줄었다.  분할 하나가
-- 어긋난 게 아니라 **래스터 IRQ 한 회차가 통째로 안 돈 것**이다.  주기도
-- "음성마다 한 번, 짧게" 로 번쩍임 증상과 같다.
--
-- 왜 그것만으로는 못 닫나
-- ---------------------------------------------------------------------------
-- 첫 조각 프레임은 게임이 ADPCM 음성을 **시작하는** 프레임이기도 하다.
-- 그 프레임은 우리가 없어도 원래 바쁘다.  그러므로 0.4.94 의 신호만으로는
--
--     A  우리 업로드가 IRQ 를 밀어냈다
--     B  게임이 음성 시작 프레임에서 원래 한 회차를 흘린다
--
-- 를 못 가른다.  **MISS 음성이 그 통제다** -- 자막이 없어 우리는 아무것도
-- 안 하는데 게임은 똑같이 ADPCM 을 시작한다.
--
-- 무엇을 재나
-- ---------------------------------------------------------------------------
-- 프레임을 네 갈래로 나눠 BYR 쓰기 횟수의 분포를 따로 쌓는다.
--
--     idle    아무 일도 없는 프레임            <- 기준 분포
--     miss    자막 없는 음성이 시작된 프레임    <- ★ 통제군
--     first   자막 음성의 첫 조각을 올린 프레임 <- ★ 실험군
--     later   두 번째 이후 조각을 올린 프레임
--
-- 판정
--     miss 도 first 처럼 낮으면    게임이 원래 흘린다.  우리 탓이 아니다  -> B
--     miss 는 idle 과 같은데
--     first 만 낮으면              우리 업로드가 IRQ 를 밀어낸다          -> A
--
-- ★ miss 표본이 0 이면 아무 판정도 하지 말 것.  MISS 음성을 몇 개 지나야 한다
--   (접수처·거리 효과음 구간에서 잘 나온다).  화면의 miss:n 을 보고 판단한다.
--
-- Power Cycle 뒤 이 파일 하나만 로드한다.

dofile('C:/snatcher/lua/SUB/0.4.89-vdc-rearm.lua')

local info = rawget(_G, 'SUB_REARM_INFO')
local ENGINE_LO = info and info.engine_lo or 0x5B80
local COUNT_OK = ENGINE_LO + (info and info.offsets.count_ok or 118)

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/split_control_0_4_95_' .. STAMP .. '.tsv'
local out = io.open(OUT, 'w')
if out then out:write('frame\tclass\tkey\tcr\trcr\tbxr\tbyr\n') end

local selReg = 0
local cnt = { [0x05] = 0, [0x06] = 0, [0x07] = 0, [0x08] = 0 }
local portHits = 0

emu.addMemoryCallback(function(address, value)
  local port = address & 3
  portHits = portHits + 1
  if port == 0 then
    selReg = (value or 0) & 0xFF
  elseif port == 2 then
    if cnt[selReg] then cnt[selReg] = cnt[selReg] + 1 end
  end
end, emu.callbackType.write, 0x0000, 0x0003, CPU, MEM)

-- 로그 사슬에서 KEY / MISS 를 잡는다.  prevLog 를 반드시 다시 부른다.
local curKey = '-'
local keyPending, missPending = false, false
local prevLog = emu.log
emu.log = function(message, ...)
  local text = tostring(message)
  local key = text:match('KEY #%d+ (%x+)')
  if key then curKey = key; keyPending = true end
  local miss = text:match('MISS #%d+ (%x+)')
  if miss then curKey = miss; missPending = true end
  return prevLog(message, ...)
end

local engineFrame = false
emu.addMemoryCallback(function() engineFrame = true end,
  emu.callbackType.exec, COUNT_OK, COUNT_OK, CPU, MEM)

local hist = { idle = {}, miss = {}, first = {}, later = {} }
local n = { idle = 0, miss = 0, first = 0, later = 0 }

local function bump(class, v)
  local h = hist[class]
  h[v] = (h[v] or 0) + 1
  n[class] = n[class] + 1
end

local function summary(class)
  local h, total = hist[class], n[class]
  if total == 0 then return class .. ':0' end
  local best, bestN = nil, -1
  for v, c in pairs(h) do if c > bestN then best, bestN = v, c end end
  local sum = 0
  for v, c in pairs(h) do sum = sum + v * c end
  return string.format('%s:%d 최빈%d 평균%.2f', class, total, best, sum / total)
end

local frame = 0

emu.addEventCallback(function()
  frame = frame + 1
  local cr, rcr, bxr, byr = cnt[0x05], cnt[0x06], cnt[0x07], cnt[0x08]
  cnt[0x05], cnt[0x06], cnt[0x07], cnt[0x08] = 0, 0, 0, 0

  local class
  if missPending then
    class = 'miss'; missPending = false
  elseif engineFrame then
    class = keyPending and 'first' or 'later'
    keyPending = false
  else
    class = 'idle'
  end
  engineFrame = false

  bump(class, byr)
  if class ~= 'idle' then
    prevLog(string.format('SUB 0.4.95 %df · %s · KEY %s · BYR %d · BXR %d · RCR %d · CR %d',
                          frame, class, curKey, byr, bxr, rcr, cr))
  end
  if out and class ~= 'idle' then
    out:write(string.format('%d\t%s\t%s\t%d\t%d\t%d\t%d\n',
                            frame, class, curKey, cr, rcr, bxr, byr))
    out:flush()
  end

  -- 5초마다 분포 요약
  if frame % 300 == 0 then
    prevLog('SUB 0.4.95 분포 · ' .. summary('idle') .. ' · ' .. summary('miss') ..
            ' · ' .. summary('first') .. ' · ' .. summary('later'))
  end

  emu.drawString(4, 64, string.format('0.4.95 %s | %s | %s | %s',
                 summary('idle'), summary('miss'), summary('first'), summary('later')),
                 n.miss > 0 and 0x80FF80 or 0x40C0FF, 0x000000)
end, emu.eventType.endFrame)

prevLog('SUB 0.4.95-split-skip-control armed -- idle/miss/first/later 로 나눠 BYR 분포')
prevLog('  ★ miss 표본이 0 이면 판정 불가.  MISS 음성을 몇 개 지나야 한다')
prevLog('  로그: ' .. OUT)
