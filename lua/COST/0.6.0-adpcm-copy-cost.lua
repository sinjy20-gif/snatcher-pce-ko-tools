-- 0.6.0-adpcm-copy-cost -- 671 B 복사가 실제로 몇 cycle 인지 잰다
--
--   덤프: snatcher_tool/logs/cost_v060.tsv   ★프로브와 같은 판번호
--
--   이 폴더로 옮기며 판번호를 다시 매겼다. 폴더 밖에서 0.3.0 이던 판이
--   2026-09-07 21:07 에 남긴 로그는 dump/adpcm_cost_0_3_0_20260907_210733.tsv 다.
--   내용은 같다.
--
-- 계산이 아니라 masterClock 차이로 직접 잰다. 화면에는 아무것도 안 그린다.
--
-- 무엇을 재나 -- ADPCM 자막 한 줄에 671 B 복사가 세 번 일어난다
--
--   ① AC -> AC     $F697 -> $F6F4    마스터 엔진 $1FE400 -> 활성 슬롯 $1F1F00
--                                    ★ 재사용 패치가 건너뛰는 것은 이것 하나뿐
--   ② RAM -> AC    $FC7A -> RTS      게임 데이터 $5B80 을 AC $1F0E00 으로 대피
--   ③ AC -> RAM    $FCDF -> $FD1E    대피분을 $5B80 으로 복귀
--
--   ②③ 은 재사용과 무관하게 매번 일어난다. 실측 결과 ② 의 건너뛰기
--   ($5B83 == $AD) 는 18회 전부 거짓이었다.
--
-- 그래서 답할 것
--   · ①②③ 각각 실제 몇 cycle 인가
--   · 재사용이 실제로 아끼는 양은 한 줄당 몇 cycle · 몇 ms · 프레임의 몇 %인가
--   · 재사용을 완전히 없애도 되는 수준인가, 아니면 의미가 있나
--
-- 쓰는 법
--   1) 0.6.1 BIOS + [KO] CUE 로 Power Cycle.
--   2) 이 스크립트 하나만 켠다.
--   3) ADPCM 대사가 여러 줄 나오는 장면을 지난다.
--   4) ★ 반드시 Stop 한다. 요약이 그때 나온다.
--
-- 산출물  C:/snatcher/dump/adpcm_cost_0_3_0_<시각>.tsv

local VERSION = '0.6.0'
local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce
local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = "C:/snatcher/snatcher_tool/logs/cost_v060.tsv"

-- PCE 마스터클럭 21.47727 MHz, CPU 는 그 1/3 = 7.15909 MHz
local MASTER_PER_CPU = 3
local CPU_HZ = 7159090
local FRAME_CYCLES = CPU_HZ / 60.0        -- 약 119,318

local SIGCHK  = 0xF655   -- 서명 검사 진입
local COPY    = 0xF697   -- ① AC->AC 복사 진입
local READY   = 0xF6F4   -- ① 끝 (복사 뒤 또는 서명 일치 직행)
local SAVE    = 0xFC7A   -- ② 진입
local SAVE_E  = 0xFCA9   -- ② RTS
local RESTORE = 0xFCDF   -- ③ 진입
local REST_E  = 0xFD1E   -- ③ RTS

local out = assert(io.open(OUT, 'w'))
out:write('frame\tkind\tcpu_cycles\tms\tframe_pct\tnote\n')

local frame, rows = 0, 0
local tSig, tCopy, tSave, tRest = nil, nil, nil, nil

-- 누적: {회수, cycle 합}
local acc = {
  check_only = {0, 0},   -- 서명 일치로 건너뛴 경우, 검사에 든 비용
  copy       = {0, 0},   -- ① 실제 복사
  save       = {0, 0},   -- ②
  restore    = {0, 0},   -- ③
}

local function clk()
  local ok, st = pcall(emu.getState)
  if not ok or type(st) ~= 'table' then return nil end
  return st.masterClock or st.MasterClock
end

local function rb(a) return emu.read(a, MEM) or 0 end
local function say(m) emu.log(m); print(m) end

local function candidateMapped()
  local t = {}
  for i = 0, 11 do t[#t + 1] = string.format('%02X', rb(0xF671 + i)) end
  return table.concat(t) == 'AD001AC941D01FAD001AC944'
end

local function emit(kind, cyc, note)
  local ms = cyc / CPU_HZ * 1000.0
  out:write(string.format('%d\t%s\t%d\t%.3f\t%.1f%%\t%s\n',
    frame, kind, cyc, ms, cyc / FRAME_CYCLES * 100.0, note or ''))
  rows = rows + 1
  if rows % 16 == 0 then out:flush() end
end

local function bump(k, cyc)
  acc[k][1] = acc[k][1] + 1
  acc[k][2] = acc[k][2] + cyc
end

-- ---- ① AC -> AC ------------------------------------------------------------

emu.addMemoryCallback(function()
  if candidateMapped() then tSig = clk() end
end, emu.callbackType.exec, SIGCHK, SIGCHK, CPU, MEM)

emu.addMemoryCallback(function()
  if candidateMapped() then tCopy = clk() end
end, emu.callbackType.exec, COPY, COPY, CPU, MEM)

emu.addMemoryCallback(function()
  if not candidateMapped() then return end
  local now = clk()
  if not now then return end
  if tCopy then
    local cyc = (now - tCopy) / MASTER_PER_CPU
    bump('copy', cyc)
    emit('COPY_AC_AC', cyc, '671B AC->AC 실제 복사')
    say(string.format('f%-7d COPY   %7d cyc  %.2f ms  프레임의 %.1f%%',
      frame, cyc, cyc / CPU_HZ * 1000, cyc / FRAME_CYCLES * 100))
    tCopy = nil
  elseif tSig then
    local cyc = (now - tSig) / MASTER_PER_CPU
    bump('check_only', cyc)
    emit('REUSE_CHECK', cyc, '서명 일치 -> 복사 생략. 검사에만 든 비용')
    say(string.format('f%-7d REUSE  %7d cyc  (검사만)', frame, cyc))
  end
  tSig = nil
end, emu.callbackType.exec, READY, READY, CPU, MEM)

-- ---- ② RAM -> AC (대피) ----------------------------------------------------

emu.addMemoryCallback(function() tSave = clk() end,
  emu.callbackType.exec, SAVE, SAVE, CPU, MEM)

emu.addMemoryCallback(function()
  if not tSave then return end
  local now = clk()
  if now then
    local cyc = (now - tSave) / MASTER_PER_CPU
    bump('save', cyc)
    emit('SAVE_RAM_AC', cyc, '게임 데이터 671B 대피')
  end
  tSave = nil
end, emu.callbackType.exec, SAVE_E, SAVE_E, CPU, MEM)

-- ---- ③ AC -> RAM (복귀) ----------------------------------------------------

emu.addMemoryCallback(function() tRest = clk() end,
  emu.callbackType.exec, RESTORE, RESTORE, CPU, MEM)

emu.addMemoryCallback(function()
  if not tRest then return end
  local now = clk()
  if now then
    local cyc = (now - tRest) / MASTER_PER_CPU
    bump('restore', cyc)
    emit('RESTORE_AC_RAM', cyc, '게임 데이터 671B 복귀')
  end
  tRest = nil
end, emu.callbackType.exec, REST_E, REST_E, CPU, MEM)

emu.addEventCallback(function() frame = frame + 1 end, emu.eventType.endFrame)

-- ---- 요약 -------------------------------------------------------------------

emu.addEventCallback(function()
  local function avg(k)
    local n, s = acc[k][1], acc[k][2]
    if n == 0 then return 0, 0 end
    return n, s / n
  end

  say('')
  say(string.format('끝  프레임 %d', frame))
  say('')
  say('  구간                     회수    평균 cycle     평균 ms   프레임 대비')
  say('  ------------------------------------------------------------------')
  for _, k in ipairs({ 'copy', 'check_only', 'save', 'restore' }) do
    local n, a = avg(k)
    local label = ({ copy = '① AC->AC 복사', check_only = '① 서명일치(검사만)',
                     save = '② RAM->AC 대피', restore = '③ AC->RAM 복귀' })[k]
    say(string.format('  %-22s %5d  %10d  %10.3f  %8.1f%%',
      label, n, a, a / CPU_HZ * 1000, a / FRAME_CYCLES * 100))
  end

  local nC, aC = avg('copy')
  local nR, aR = avg('check_only')
  say('')
  if nC > 0 and nR > 0 then
    local saved = aC - aR
    say(string.format('  재사용이 한 줄당 실제로 아끼는 양: %d cycle  %.3f ms  프레임의 %.1f%%',
      saved, saved / CPU_HZ * 1000, saved / FRAME_CYCLES * 100))
    say(string.format('  이번 측정 구간 전체 절감: %d cycle  %.1f ms  (%d 줄)',
      saved * nR, saved * nR / CPU_HZ * 1000, nR))
  elseif nC > 0 then
    say('  재사용이 한 번도 안 걸렸다. 비교값 없음')
  else
    say('  ADPCM 무장 지점을 안 지났다')
  end

  local _, aS = avg('save')
  local _, aRe = avg('restore')
  say('')
  say(string.format('  참고: ②③ 은 재사용과 무관하게 매번 일어난다. 합 %.3f ms/줄',
    (aS + aRe) / CPU_HZ * 1000))

  out:write('#\n')
  for _, k in ipairs({ 'copy', 'check_only', 'save', 'restore' }) do
    local n, a = avg(k)
    out:write(string.format('# %s n=%d avg_cycles=%d\n', k, n, a))
  end
  out:close()
  say('')
  say('-> ' .. OUT)
end, emu.eventType.scriptEnded)

say('COST ' .. VERSION .. ' adpcm-copy-cost' .. ' -- 화면 표시 없음')
say('  671B 복사 ①②③ 을 masterClock 으로 직접 잰다')
say('  ADPCM 대사를 여러 줄 지난 뒤 Stop 하면 요약이 나온다')
say('-> ' .. OUT)
