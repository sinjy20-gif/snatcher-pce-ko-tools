-- SUB 0.5.195 -- ADPCM $180D 를 누가 읽는가 (경량판)  ★순수 관측 · 쓰기 0 B · 화면에 안 그림
--
-- 0.5.194 가 왜 느렸나 -- 세 가지가 곱해졌다
--   ① 걸개를 $1800-$180F 전 구간에 걸었다.  CD 레지스터는 프레임당 수천 번 읽힌다
--   ② 접근마다 emu.getState() 를 불렀다 (제일 비싼 호출)
--   ③ 줄마다 flush 했다
--
-- 이 판은 셋 다 고쳤다
--   ① $180D 한 곳만.  ($180C 는 값 분포만, PC 는 안 뜬다)
--   ② PC 는 **표본만** 뜬다 -- 16 번에 한 번 + 비트5 가 바뀌는 순간(드물다)은 항상
--      히스토그램의 1 등을 찾는 데는 표본으로 충분하다
--   ③ 버퍼에 모아 2 초에 한 번만 flush
--
-- 무엇을 재나 / 판정 은 0.5.194 와 같다
--   비트5 하강 > 0   -> 이 환경은 종료 통보를 준다 (메센 기준선)
--   비트5 하강 == 0  -> ★이 비트로 종료를 안 알린다.  기다리는 관문은 안 열린다
--   $180D 읽기 == 0  -> 음성 구간을 안 지났거나 엔진이 이 경로를 안 본다
--
-- 쓰는 법  장면 안 맞춰도 된다.  음성 나오는 구간을 지나고 Stop
--
-- 산출물  C:/snatcher/dump/poll180d_0_5_195_<시각>_events.tsv
--         C:/snatcher/dump/poll180d_0_5_195_<시각>_summary.txt

local D, C = 0x180D, 0x180C
local PC_SAMPLE = 16          -- 16 번에 한 번만 PC 를 뜬다
local MAX_ROWS  = 1500
local REPORT    = 300

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local BASE  = 'C:/snatcher/dump/poll180d_0_5_195_' .. STAMP

local eout = assert(io.open(BASE .. '_events.tsv', 'w'))
eout:write('frame\twhat\tvalue\tbit5\tpc\n')

local function say(m) emu.log(m); print(m) end

local PC_KEY
local function pcNow()
  local ok, s = pcall(emu.getState)
  if not ok or type(s) ~= 'table' then return -1 end
  if PC_KEY == nil then
    PC_KEY = false
    for _, k in ipairs({ 'cpu.pc', 'cpu.programCounter', 'pc', 'cpu.PC' }) do
      if type(s[k]) == 'number' then PC_KEY = k break end
    end
  end
  if PC_KEY == false then return -1 end
  local v = s[PC_KEY]
  return type(v) == 'number' and (math.floor(v) & 0xFFFF) or -1
end

local frame, rows = 0, 0
local nD, nC = 0, 0
local pcD, valD, valC = {}, {}, {}
local lastBit5, nFall, nRise = nil, 0, 0
local fallRows = {}
local tick = 0

local function row(what, v, b5, pc)
  if rows >= MAX_ROWS then return end
  rows = rows + 1
  eout:write(('%d\t%s\t$%02X\t%s\t%s\n'):format(
    frame, what, v & 0xFF,
    b5 == nil and '' or tostring(b5),
    pc and ('$%04X'):format(pc) or ''))
end

emu.addMemoryCallback(function(address, value)
  local v = (value or 0) & 0xFF
  nD = nD + 1
  valD[v] = (valD[v] or 0) + 1

  local b5 = (v & 0x20) ~= 0
  local changed = (lastBit5 ~= nil and lastBit5 ~= b5)
  lastBit5 = b5

  tick = tick + 1
  local wantPc = changed or (tick % PC_SAMPLE == 0) or nD <= 20
  local pc = wantPc and pcNow() or nil
  if pc then pcD[pc] = (pcD[pc] or 0) + 1 end

  if changed then
    if not b5 then
      nFall = nFall + 1
      if #fallRows < 30 then
        fallRows[#fallRows + 1] = ('f%d  PC $%04X  $%02X'):format(frame, pc or -1, v)
      end
      row('BIT5_FALL', v, b5, pc)
    else
      nRise = nRise + 1
      row('BIT5_RISE', v, b5, pc)
    end
  elseif nD <= 20 then
    row('READ', v, b5, pc)
  end
end, emu.callbackType.read, D, D, CPU, MEM)

emu.addMemoryCallback(function(address, value)
  local v = (value or 0) & 0xFF
  nC = nC + 1
  valC[v] = (valC[v] or 0) + 1
end, emu.callbackType.read, C, C, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  if frame % 120 == 0 then eout:flush() end
  if frame % REPORT == 0 then
    say(('f%d  $180D %d · $180C %d · 비트5 하강 %d / 상승 %d')
        :format(frame, nD, nC, nFall, nRise))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  eout:close()
  local s = assert(io.open(BASE .. '_summary.txt', 'w'))
  local function put(m) s:write(m .. '\n'); say(m) end
  local function top(name, t, fmt, n)
    local r = {}
    for v, c in pairs(t) do r[#r + 1] = { v = v, c = c } end
    table.sort(r, function(x, y) return x.c > y.c end)
    put(('%s (%d 가지)'):format(name, #r))
    for i = 1, math.min(#r, n or 12) do put(('    ' .. fmt):format(r[i].v, r[i].c)) end
  end

  put(('프레임 %d'):format(frame))
  put(('$180D 읽기 %d · $180C 읽기 %d'):format(nD, nC))
  put(('비트5 하강 %d · 상승 %d'):format(nFall, nRise))
  put('')
  if nD == 0 then
    put('★ $180D 를 아무도 안 읽었다.  0 은 "이상 없음" 이 아니다.')
    put('   음성 나오는 구간을 지나서 다시 잴 것.')
  else
    put(('★ $180D 를 읽는 PC -- %d 번에 1 표본 + 비트5 변화는 전수'):format(PC_SAMPLE))
    top('', pcD, 'PC $%04X   %d 회')
    put('')
    top('$180D 가 돌려준 값', valD, '$%02X   %d 회')
    put('')
    if nC > 0 then top('$180C 가 돌려준 값', valC, '$%02X   %d 회', 8) put('') end
    if nFall == 0 then
      put('★★ 비트5 가 한 번도 안 떨어졌다 -- 이 환경은 종료를 이 비트로 안 알린다.')
    else
      put('비트5 하강 시점')
      for _, r in ipairs(fallRows) do put('    ' .. r) end
    end
  end
  s:close()
  say('  ' .. BASE .. '_summary.txt')
end, emu.eventType.scriptEnded)

say('SUB 0.5.195-poll180d-light armed -- $180D 만 · PC 는 표본 · 쓰기 0 B')
say('  음성 나오는 구간을 지나고 Stop')
say('  ' .. BASE .. '_events.tsv')
