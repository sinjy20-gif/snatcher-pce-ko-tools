-- PROBE_STALL 0.1.1  --  "다음 음원이 안 나온다" 를 잰다
--
-- 0.1.1: 보고를 **파일로** 쓴다.  30 초마다 자동으로 다시 쓴다.
--        0.1.0 은 emu.log 에만 찍어서 Stop 하고 복붙해야 읽혔다.
--        멈춘 채로 30 초만 두면 파일이 알아서 최신이 된다 -- Stop 안 눌러도 된다.
--
-- 무엇을 재나
-- -----------
-- 음성 하나가 끝난 뒤 다음이 안 나오고 게임 진행이 멈춘다.  게임은 살아 있다
-- (미카 눈이 깜빡인다).  그러면 **스크립트가 무언가를 기다리는 중**이다.
-- 무엇을 기다리는지 짐작하지 않고 잡는다.
--
--     1  CPU 가 어디서 도는가          PC 를 매 프레임 찍어 히스토그램
--     2  ADPCM 포트를 얼마나 두드리나   $180C 읽기 · $180D 쓰기 횟수
--     3  cdrom 상태 중 무엇이 얼어 있나  전 키를 떠서 **안 변하는 것**을 가려낸다
--
-- 3 번이 핵심이다.  기다림은 "어떤 값이 바뀌기를 기다리는 것" 이므로, 멈춘 동안
-- 무엇이 안 변하는지가 곧 답이다.
--
-- ★ 이 스크립트는 **아무것도 안 쓴다.**  ADPCM RAM 도 안 읽는다 -- 그것이 지금
-- 용의자이기 때문이다.  용의자를 쓰는 도구로 용의자를 재면 안 된다.
--
-- 쓰는 법
-- -------
--   PROBE_SUB_PACK 과 **같이** 올린다 (Mesen 은 스크립트 창을 여럿 연다).
--   멈춘 뒤 10 초쯤 두었다가 Stop.  표가 나온다.
--
--   자막 프로브 없이 혼자 올려서도 돌려 볼 것.  그래야 "자막 프로브가 원인인가"
--   가 갈린다.

local MEM = emu.memType.pceMemory
local STAMP = os.date('%Y%m%d_%H%M%S')
local OUTPATH = 'C:/snatcher/dump/probe_stall_0_1_1_' .. STAMP .. '.tsv'
local KEYPATH = 'C:/snatcher/dump/probe_stall_keys_' .. STAMP .. '.txt'
-- ★ 보고는 여기 쌓인다.  30 초마다 덮어쓴다.
local REPORTPATH = 'C:/snatcher/dump/probe_stall_REPORT_' .. STAMP .. '.txt'

-- ADPCM 포트.  STATE 문서 §4.3 이 잡아 둔 자리다.
--   $F61A  STA $180D   재생 시작 루틴의 마지막 줄
--   $F6EF  LDA $180C   상태 폴링 루틴
local PORT_LO, PORT_HI = 0x1800, 0x180F

local frames = 0
local port_read, port_write = {}, {}
local pc_hist = {}
local pc_key = nil

local report = {}
local function put(s) report[#report + 1] = s end
local function say(s) emu.log(s); put(s) end

-- ---------------------------------------------------------------- 상태 뜨기
local prev = {}          -- 키 -> 마지막 값
local frozen = {}        -- 키 -> 안 변한 프레임 수
local changed = {}       -- 키 -> 변한 횟수
local watch_keys = nil

local function fmt(v)
  if type(v) == 'boolean' then return v and '1' or '0' end
  if type(v) == 'number' then return string.format('%d', math.floor(v)) end
  return tostring(v)
end

local function collect_keys(state)
  local out = {}
  for k, v in pairs(state) do
    if type(k) == 'string' and (type(v) == 'number' or type(v) == 'boolean') then
      -- cdrom 전부 + cpu 전부.  나머지는 너무 많다.
      if k:sub(1, 6) == 'cdrom.' or k:sub(1, 4) == 'cpu.' then
        out[#out + 1] = k
      end
    end
  end
  table.sort(out)
  return out
end

-- PC 키 이름은 판마다 다를 수 있다.  이름으로 찾는다.
local function find_pc(state)
  for _, name in ipairs({ 'cpu.pc', 'cpu.PC', 'pc' }) do
    if type(state[name]) == 'number' then return name end
  end
  for k, v in pairs(state) do
    if type(k) == 'string' and type(v) == 'number' and k:lower():find('%.pc$') then
      return k
    end
  end
  return nil
end

-- ---------------------------------------------------------------- 포트 감시
local function port_cb_read(addr)
  port_read[addr] = (port_read[addr] or 0) + 1
end
local function port_cb_write(addr)
  port_write[addr] = (port_write[addr] or 0) + 1
end

emu.addMemoryCallback(function(addr) port_cb_read(addr) end,
  emu.callbackType.read, PORT_LO, PORT_HI, emu.cpuType.pce, MEM)
emu.addMemoryCallback(function(addr) port_cb_write(addr) end,
  emu.callbackType.write, PORT_LO, PORT_HI, emu.cpuType.pce, MEM)

-- ---------------------------------------------------------------- 한 프레임
local samples = {}
local last_read_total, last_write_total = 0, 0

local function totals(t)
  local n = 0
  for _, v in pairs(t) do n = n + v end
  return n
end

emu.addEventCallback(function()
  frames = frames + 1
  local state = emu.getState()

  if watch_keys == nil then
    watch_keys = collect_keys(state)
    pc_key = find_pc(state)
    local f = io.open(KEYPATH, 'w')
    if f then
      f:write('getState 의 cdrom.* / cpu.* 키 ' .. #watch_keys .. ' 개\n')
      for _, k in ipairs(watch_keys) do
        f:write(string.format('%-40s %s\n', k, fmt(state[k])))
      end
      f:close()
    end
    say(string.format('감시 키 %d 개 · PC 키 %s', #watch_keys, tostring(pc_key)))
    say('  -> ' .. KEYPATH)
  end

  for _, k in ipairs(watch_keys) do
    local v = fmt(state[k])
    if prev[k] == nil then
      prev[k] = v
      frozen[k] = 0
      changed[k] = 0
    elseif prev[k] == v then
      frozen[k] = frozen[k] + 1
    else
      prev[k] = v
      frozen[k] = 0
      changed[k] = changed[k] + 1
    end
  end

  if pc_key then
    local pc = math.floor(state[pc_key] or 0)
    -- 256 B 칸으로 뭉쳐 센다.  정확한 주소보다 "어느 동네" 가 먼저다.
    local bucket = pc & 0xFF00
    pc_hist[bucket] = (pc_hist[bucket] or 0) + 1
  end

  -- 1 초마다 한 줄
  if frames % 60 == 0 then
    local rt, wt = totals(port_read), totals(port_write)
    samples[#samples + 1] = string.format('%d\t%s\t%s\t%s\t%s\t%d\t%d',
      frames,
      fmt(state['cdrom.adpcm.playing']),
      fmt(state['cdrom.adpcm.readAddress']),
      fmt(state['cdrom.adpcm.writeAddress']),
      fmt(state['cdrom.adpcm.adpcmLength']),
      rt - last_read_total, wt - last_write_total)
    last_read_total, last_write_total = rt, wt
  end
end, emu.eventType.endFrame)

-- ---------------------------------------------------------------- 보고
local function write_report()
  local f = io.open(REPORTPATH, 'w')
  if f == nil then return end
  for _, l in ipairs(report) do f:write(l .. '\n') end
  f:close()
end

local function make_report()
  report = {}
  put('')
  put(string.format('== PROBE_STALL == %d 프레임 (%.1f 초)', frames, frames / 60.0))

  -- 1) CPU 가 어디서 도는가
  local hot = {}
  for b, n in pairs(pc_hist) do hot[#hot + 1] = { b = b, n = n } end
  table.sort(hot, function(a, b) return a.n > b.n end)
  put('')
  put('[1] CPU 가 머문 곳 (PC 를 256 B 칸으로)')
  for i = 1, math.min(6, #hot) do
    put(string.format('    $%04X-$%04X   %6d 프레임  %5.1f%%',
      hot[i].b, hot[i].b + 0xFF, hot[i].n, 100.0 * hot[i].n / math.max(1, frames)))
  end
  if #hot > 0 and hot[1].n > frames * 0.5 then
    put('    ★ 절반 넘게 한 동네에 있다 -- 여기가 기다리는 루프다')
  end

  -- 2) ADPCM 포트
  put('')
  put('[2] ADPCM 포트 $1800-$180F')
  local any = false
  for a = PORT_LO, PORT_HI do
    local r, w = port_read[a] or 0, port_write[a] or 0
    if r > 0 or w > 0 then
      any = true
      put(string.format('    $%04X  읽기 %8d · 쓰기 %8d', a, r, w))
    end
  end
  if not any then put('    (한 번도 안 건드렸다)') end

  -- 3) 무엇이 얼어 있나  ★ 이게 핵심이다
  put('')
  put('[3] cdrom 상태 -- 마지막까지 안 변한 것 (기다림의 대상)')
  local cold, warm = {}, {}
  for _, k in ipairs(watch_keys or {}) do
    if k:sub(1, 6) == 'cdrom.' then
      if (changed[k] or 0) == 0 then
        cold[#cold + 1] = k
      else
        warm[#warm + 1] = { k = k, n = changed[k], f = frozen[k] }
      end
    end
  end
  table.sort(warm, function(a, b) return a.f > b.f end)
  put(string.format('    한 번도 안 변한 키 %d 개:', #cold))
  for i = 1, math.min(10, #cold) do
    put(string.format('       %-38s = %s', cold[i], prev[cold[i]] or '?'))
  end
  put('    변했다가 멈춘 지 오래된 것 (마지막 변화 이후 프레임):')
  for i = 1, math.min(8, #warm) do
    put(string.format('       %-38s 얼음 %6d f · 변화 %d 회',
      warm[i].k, warm[i].f, warm[i].n))
  end

  local f = io.open(OUTPATH, 'w')
  if f then
    f:write('frame\tplaying\treadAddr\twriteAddr\tlength\tport_read\tport_write\n')
    for _, s in ipairs(samples) do f:write(s .. '\n') end
    f:close()
    put('')
    put('    -> ' .. OUTPATH)
  end
  write_report()
end

-- 30 초마다 스스로 보고를 갱신한다.  멈춘 채로 두기만 하면 된다.
emu.addEventCallback(function()
  if frames % 1800 == 0 and frames > 0 then make_report() end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  make_report()
  emu.log('보고 -> ' .. REPORTPATH)
end, emu.eventType.scriptEnded)

emu.log('PROBE_STALL 0.1.1 loaded  --  아무것도 안 쓴다 · ADPCM RAM 도 안 읽는다')
emu.log('  ★ Stop 안 눌러도 된다.  멈춘 채로 30 초 두면 보고가 파일에 쌓인다')
emu.log('  보고 -> ' .. REPORTPATH)
emu.log('  표   -> ' .. OUTPATH)
