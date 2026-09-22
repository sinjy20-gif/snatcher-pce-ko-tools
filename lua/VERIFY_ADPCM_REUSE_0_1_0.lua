-- VERIFY_ADPCM_REUSE 0.1.0 -- RC3의 671 B 엔진 재사용 분기 실측
--
-- 화면에는 아무것도 그리지 않는다. Script 창과 종료 시 TSV에만 기록한다.
-- RC3 dispatcher의 실제 실행 주소를 직접 센다.
--
--   $F697 arm_engine_copy  : 서명 불일치, 671 B 전체 복사 경로
--   $F6F4 arm_engine_ready : 전체 복사 뒤 또는 서명 일치 직행 지점
--
-- 쓰는 법:
--   1) 0.6.0-rc3-adpcm-reuse BIOS+CUE를 Power Cycle로 시작한다.
--   2) 이 스크립트 하나만 켠다.
--   3) ADPCM 대사가 연속되는 장면을 진행한다.
--   4) Script 창에서 REUSE가 증가하는지 본다.

local VERSION = '0.1.0'
local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce
local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/snatcher_tool/logs/adpcm_reuse_verify_' .. STAMP .. '.tsv'

local ARM_FOUND = 0xF5B9
local COPY = 0xF697
local READY = 0xF6F4

local arms = 0
local copies = 0
local reuses = 0
local ready = 0
local pendingCopy = false
local rows = {}

local function rb(a)
  return emu.read(a, MEM) or 0
end

local function hx(a, n)
  local t = {}
  for i=0,n-1 do t[#t+1] = string.format('%02X', rb(a+i)) end
  return table.concat(t, '')
end

local function candidateMapped()
  -- $F671: LDA $1A00 / CMP #$41 / BNE ... / LDA $1A00 / CMP #$44
  return hx(0xF671, 12) == 'AD001AC941D01FAD001AC944'
end

local function record(kind)
  rows[#rows+1] = {
    frame = emu.getState()['masterClock'] or 0,
    kind = kind,
    arms = arms,
    copies = copies,
    reuses = reuses,
  }
  emu.log(string.format(
    'ADPCM reuse: %-8s  arm=%d  COPY=%d  REUSE=%d',
    kind, arms, copies, reuses))
end

emu.addMemoryCallback(function()
  if candidateMapped() then arms = arms + 1 end
end, emu.callbackType.exec, ARM_FOUND, ARM_FOUND, CPU, MEM)

emu.addMemoryCallback(function()
  if not candidateMapped() then return end
  pendingCopy = true
  copies = copies + 1
end, emu.callbackType.exec, COPY, COPY, CPU, MEM)

emu.addMemoryCallback(function()
  if not candidateMapped() then return end
  ready = ready + 1
  if pendingCopy then
    pendingCopy = false
    record('COPY')
  else
    reuses = reuses + 1
    record('REUSE')
  end
end, emu.callbackType.exec, READY, READY, CPU, MEM)

emu.addEventCallback(function()
  local f = io.open(OUT, 'w')
  if f then
    f:write('clock\tkind\tarms\tcopies\treuses\n')
    for _, r in ipairs(rows) do
      f:write(string.format('%s\t%s\t%d\t%d\t%d\n',
        tostring(r.frame), r.kind, r.arms, r.copies, r.reuses))
    end
    f:close()
  end
  emu.log(string.format(
    'VERIFY_ADPCM_REUSE 종료: arm=%d ready=%d COPY=%d REUSE=%d',
    arms, ready, copies, reuses))
  if ready == 0 then
    emu.log('  판정 불가: RC3가 아니거나 ADPCM 자막 무장 지점을 지나지 않았다.')
  elseif reuses == 0 then
    emu.log('  재사용 0회: 활성 슬롯의 서명이 유지되지 않았다.')
  else
    emu.log('  재사용 분기 확인: 671 B 복사를 실제로 생략했다.')
  end
  emu.log('  log: ' .. OUT)
end, emu.eventType.scriptEnded)

emu.log('VERIFY_ADPCM_REUSE ' .. VERSION .. ' -- 화면 표시 없는 RC3 실측기')
emu.log('  COPY/REUSE가 ADPCM 대사마다 한 줄씩 찍힌다.')
emu.log('  현재 RC3 코드 매핑: ' .. (candidateMapped() and 'YES' or '아직 아님'))
emu.log('  log: ' .. OUT)

