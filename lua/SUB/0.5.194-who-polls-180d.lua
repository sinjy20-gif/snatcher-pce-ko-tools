-- SUB 0.5.194 -- ADPCM 레지스터를 **누가** 읽는가  ★순수 관측 · 쓰기 0 B · 화면에 안 그림
--
-- 왜 방식을 바꿨나
-- ---------------------------------------------------------------------------
-- 0.5.192  $FED7 진입 0  -> 그 블록은 죽은 코드였다 (direct_return_patch)
-- 0.5.193  $FC38 진입 0  -> 뱅크1 이 $E000 에 얹힌 순간을 못 잡았거나 자리가 틀렸다
--          게다가 $7FDF 는 $6000-$7FFF 라 **뱅크 종속**이다.  그냥 읽으면 0 만 나온다
--
-- 두 번 다 내가 주소를 먼저 찍고 거기 걸었다.  이번엔 반대로 간다:
-- **하드웨어 레지스터에 걸고, 누가 읽는지 PC 로 역추적한다.**
-- $1800-$180F 는 뱅크와 무관한 I/O 페이지라 이 걸개는 어디서 부르든 걸린다.
--
-- 무엇을 재나
-- ---------------------------------------------------------------------------
--   1) $180D · $180C 읽기 전수 -- **PC 히스토그램**  ★이게 본체
--      살아 있는 폴링 루프의 진짜 주소가 여기서 나온다
--   2) 그때 돌려준 값의 분포 (읽기 콜백의 value)
--   3) $180D 비트5 가 켜짐->꺼짐 으로 **떨어지는 순간**의 프레임과 PC
--      = ADPCM 이 끝났다고 이 환경이 알려주는 시점
--   4) $1800-$180F 전 구간 접근 계수 (어떤 레지스터를 쓰는지 지도)
--
-- 판정
--   PC 히스토그램에 상위 몇 개    -> 그게 살아 있는 폴링 자리다.  다음 프로브는 거기 건다
--   비트5 하강이 잡힌다           -> 이 환경에선 종료 통보가 온다 (메센 기준선)
--   $180D 읽기가 0                -> ★ADPCM 을 이 경로로 안 본다.  다른 신호를 쓴다는 뜻
--   읽기는 있는데 비트5 가 늘 1    -> 종료 통보가 안 온다
--
-- 쓰는 법
--   ★장면을 맞출 필요 없다.  음성이 한 번이라도 나오면 잡힌다.
--   1) 이것만 로드.  정상 속도
--   2) 음성이 나오는 구간을 지난다 (아무 대사나 좋다)
--   3) Stop -> _summary.txt
--
-- 산출물  C:/snatcher/dump/poll180d_0_5_194_<시각>_events.tsv
--         C:/snatcher/dump/poll180d_0_5_194_<시각>_summary.txt

local R_LO, R_HI = 0x1800, 0x180F
local D, C = 0x180D, 0x180C
local MAX_ROWS = 3000
local REPORT   = 300

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local BASE  = 'C:/snatcher/dump/poll180d_0_5_194_' .. STAMP

local eout = assert(io.open(BASE .. '_events.tsv', 'w'))
eout:write('frame\twhat\taddr\tvalue\tbit5\tpc\n')
eout:flush()

local function say(m) emu.log(m); print(m) end

local function makeReader(cands)
  local key
  return function()
    local ok, s = pcall(emu.getState)
    if not ok or type(s) ~= 'table' then return -1 end
    if key == nil then
      key = false
      for _, k in ipairs(cands) do
        if type(s[k]) == 'number' then key = k break end
      end
    end
    if key == false then return -1 end
    local v = s[key]
    return type(v) == 'number' and (math.floor(v) & 0xFFFF) or -1
  end
end
local pcNow = makeReader({ 'cpu.pc', 'cpu.programCounter', 'pc', 'cpu.PC' })

local frame, rows = 0, 0
local regHits = {}            -- 레지스터별 접근 수
local pcD, pcC = {}, {}       -- $180D / $180C 를 읽는 PC 분포
local valD, valC = {}, {}     -- 값 분포
local nD, nC = 0, 0
local lastBit5, nFall, nRise = nil, 0, 0
local fallRows = {}

local function row(what, addr, value, bit5)
  if rows >= MAX_ROWS then return end
  rows = rows + 1
  eout:write(('%d\t%s\t$%04X\t$%02X\t%s\t$%04X\n')
    :format(frame, what, addr, value & 0xFF, bit5 == nil and '' or tostring(bit5), pcNow()))
  eout:flush()
end

emu.addMemoryCallback(function(address, value)
  local v = (value or 0) & 0xFF
  local pc = pcNow()
  regHits[address] = (regHits[address] or 0) + 1

  if address == D then
    nD = nD + 1
    pcD[pc] = (pcD[pc] or 0) + 1
    valD[v] = (valD[v] or 0) + 1
    local b5 = (v & 0x20) ~= 0
    if lastBit5 ~= nil and lastBit5 ~= b5 then
      if lastBit5 and not b5 then
        nFall = nFall + 1
        if #fallRows < 40 then
          fallRows[#fallRows + 1] = ('f%d  PC $%04X  $%02X'):format(frame, pc, v)
        end
        row('BIT5_FALL', address, v, b5)
      else
        nRise = nRise + 1
        row('BIT5_RISE', address, v, b5)
      end
    end
    lastBit5 = b5
    if nD <= 60 then row('READ_180D', address, v, b5) end
  elseif address == C then
    nC = nC + 1
    pcC[pc] = (pcC[pc] or 0) + 1
    valC[v] = (valC[v] or 0) + 1
    if nC <= 30 then row('READ_180C', address, v, nil) end
  end
end, emu.callbackType.read, R_LO, R_HI, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  if frame % REPORT == 0 then
    say(('f%d  $180D 읽기 %d · $180C 읽기 %d · 비트5 하강 %d / 상승 %d')
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
    for i = 1, math.min(#r, n or 12) do
      put(('    ' .. fmt):format(r[i].v, r[i].c))
    end
  end

  put(('프레임 %d'):format(frame))
  put(('$180D 읽기 %d · $180C 읽기 %d'):format(nD, nC))
  put(('비트5 하강 %d · 상승 %d'):format(nFall, nRise))
  put('')

  if nD == 0 and nC == 0 then
    put('★ ADPCM 상태 레지스터를 아무도 안 읽었다.')
    put('   음성이 한 번도 안 나온 구간이거나, 이 엔진은 다른 신호를 쓴다.')
    put('   0 은 "이상 없음" 이 아니다 -- 음성 나오는 구간을 지나서 다시 잴 것.')
  else
    top('★ $180D 를 읽는 PC (여기가 살아 있는 폴링 자리다)', pcD, 'PC $%04X   %d 회')
    put('')
    top('$180D 가 돌려준 값', valD, '$%02X   %d 회')
    put('')
    if nC > 0 then
      top('$180C 를 읽는 PC', pcC, 'PC $%04X   %d 회', 8)
      put('')
      top('$180C 가 돌려준 값', valC, '$%02X   %d 회', 8)
      put('')
    end
    if nFall == 0 then
      put('★★ 비트5 가 한 번도 안 떨어졌다 -- 이 환경은 "ADPCM 끝남" 을 이 비트로 안 알린다.')
      put('   철거 관문이 이 비트를 기다린다면 영영 안 열린다.')
    else
      put(('비트5 하강 시점 (앞 %d 개)'):format(math.min(#fallRows, 40)))
      for _, r in ipairs(fallRows) do put('    ' .. r) end
    end
  end
  put('')
  top('$1800-$180F 레지스터별 접근', regHits, '$%04X   %d 회', 16)
  s:close()
  say('  ' .. BASE .. '_summary.txt')
end, emu.eventType.scriptEnded)

say('SUB 0.5.194-who-polls-180d armed -- $1800-$180F 읽기 감시 · 쓰기 0 B · 화면에 안 그림')
say('  ★장면 안 맞춰도 된다.  음성 나오는 구간을 지나고 Stop')
say('  ' .. BASE .. '_events.tsv')
