-- PROBE_SCREEN_WIDTH 0.1.1  --  표시 폭.  경로를 추측하지 않는다
--
-- 0.1.0 이 왜 실패했나
-- ------------------
--   ★ emu.getState().vdc 를 못 읽었다
--
-- PROBE_SPRITE_BUDGET 0.1.0 에서는 vdc.hvReg / vdc.hvLatch 가 찍혔다.  그건
-- 루트부터 재귀로 훑어서 나온 **경로 문자열**이었지, st.vdc 가 테이블이라는
-- 확인이 아니었다.  0.1.1 은 두 가지를 같이 한다.
--
--   A  구조를 먼저 찍고 들어간다.  최상위 키와 타입을 그대로 나열한다.
--      중간에 못 읽어도 return 하지 않는다 -- 무엇이 있는지가 결과다.
--
--   B  getState 에 의존하지 않는 길.  게임이 VDC 레지스터에 쓰는 것을 직접 잡는다.
--        CPU $0000 = 레지스터 선택   $0002/$0003 = 데이터 하위/상위
--        reg $0A HSR = HSW | HDS<<8      reg $0B HDR = HDW | HDE<<8
--        표시 폭 px = (HDW + 1) * 8
--      게임 자신이 쓰는 값이므로 이게 가장 확실하다.
--      ST0/ST1/ST2 도 같은 포트에 쓰므로 같이 잡힌다.
--
-- 왜 이 숫자가 필요한가
--   snatcher_ko_master.tsv 는 4640 행 전부 max_cells = 18 이고, 번역이 이미
--   18 셀 한 줄에 맞춰져 있다 (18 셀에 99.7% 가 들어간다).
--   18 자 x 16 px = 288 px.  256 보다 넓다.  즉 표시 폭이 256 이 아니다.
--   그 실제 값이 자막 한 줄의 좌표를 전부 결정한다.
--
-- 아무것도 안 쓴다.
-- 출력  로그 + C:/snatcher/dump/probe_screen_width_0_1_1_<날짜>.tsv

local MEM = emu.memType.pceMemory

local frames, dumped = 0, false
local sel = -1                       -- 마지막으로 선택된 VDC 레지스터
local hsr, hdr = nil, nil
local reported = false
local lines = {}
local function say(s) emu.log(s); lines[#lines+1] = s end

local function save()
  local f = io.open(string.format('C:/snatcher/dump/probe_screen_width_0_1_1_%s.tsv',
                                  os.date('%Y%m%d_%H%M%S')), 'w')
  if f then
    f:write('line\n')
    for _, s in ipairs(lines) do f:write(s .. '\n') end
    f:close()
  end
end

-- A. 구조를 있는 그대로 찍는다
local function shape()
  local ok, st = pcall(emu.getState)
  say(string.format('emu.getState() -> ok=%s  type=%s', tostring(ok), type(st)))
  if not ok or type(st) ~= 'table' then return end

  local keys = {}
  for k in pairs(st) do keys[#keys+1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  say('--- 최상위 키 ---')
  for _, k in ipairs(keys) do
    say(string.format('    %-20s %s', tostring(k), type(st[k])))
  end

  -- 테이블인 최상위 키를 한 겹 더 열어 vdc 로 보이는 것을 찾는다
  for _, k in ipairs(keys) do
    local v = st[k]
    if type(v) == 'table' then
      local sub = {}
      for k2 in pairs(v) do sub[#sub+1] = tostring(k2) end
      table.sort(sub)
      say(string.format('--- %s (%d 키) ---', tostring(k), #sub))
      for _, k2 in ipairs(sub) do
        local v2 = v[k2]
        local lk = k2:lower()
        if type(v2) ~= 'table' then
          if lk:find('width') or lk:find('height') or lk:find('hd') or lk:find('hs')
             or lk:find('column') or lk:find('row') or lk:find('clock') then
            say(string.format('      %-24s = %s', k2, tostring(v2)))
          end
        else
          local sub2 = {}
          for k3 in pairs(v2) do sub2[#sub2+1] = tostring(k3) end
          table.sort(sub2)
          say(string.format('      %s (테이블)  %s', k2, table.concat(sub2, ' ')))
          for _, k3 in ipairs(sub2) do
            local v3 = v2[k3]
            if type(v3) ~= 'table' then
              say(string.format('          %-20s = %s', k3, tostring(v3)))
            end
          end
        end
      end
    end
  end
end

-- B. 게임이 VDC 레지스터에 쓰는 것을 직접 잡는다
local function decode()
  say('--- VDC 가로 타이밍 레지스터 (게임이 쓴 값) ---')
  if hsr then
    say(string.format('    reg $0A HSR = $%04X   HSW=%d  HDS=%d',
                      hsr, hsr % 32, math.floor(hsr / 256) % 128))
  else
    say('    reg $0A HSR  -- 못 잡았다')
  end
  if hdr then
    local hdw = hdr % 128
    local px = (hdw + 1) * 8
    say(string.format('    reg $0B HDR = $%04X   HDW=%d  HDE=%d',
                      hdr, hdw, math.floor(hdr / 256) % 128))
    say(string.format('    ★ 표시 폭 = (%d+1) * 8 = %d px', hdw, px))
    say(string.format('       16 px 글자 %d 자 (여백 %d px)',
                      math.floor(px / 16), px % 16))
    say(string.format('       18 자(288 px) %s',
                      px >= 288 and string.format('들어간다.  좌우 여백 %d px 씩', (px - 288) / 2)
                                or string.format('안 들어간다.  %d px 모자란다', 288 - px)))
  else
    say('    reg $0B HDR  -- 못 잡았다.  ST0/ST1/ST2 가 쓰기 콜백에 안 잡히는 것이다')
  end
end

emu.addMemoryCallback(function(addr, value)
  sel = value % 32
end, emu.callbackType.write, 0x0000, 0x0000, emu.cpuType.pce, MEM)

emu.addMemoryCallback(function(addr, value)
  if sel == 0x0A then hsr = (hsr or 0) % 256 + 0 end
  if addr == 0x0002 then
    if sel == 0x0A then hsr = ((hsr or 0) - ((hsr or 0) % 256)) + value end
    if sel == 0x0B then hdr = ((hdr or 0) - ((hdr or 0) % 256)) + value end
  else
    if sel == 0x0A then hsr = ((hsr or 0) % 256) + value * 256 end
    if sel == 0x0B then hdr = ((hdr or 0) % 256) + value * 256 end
  end
end, emu.callbackType.write, 0x0002, 0x0003, emu.cpuType.pce, MEM)

emu.addEventCallback(function()
  frames = frames + 1
  if not dumped and frames >= 120 then
    dumped = true
    shape()
    decode()
    save()
  end
  -- 레지스터가 늦게 잡히면 한 번 더 찍는다
  if dumped and not reported and frames >= 600 then
    reported = true
    say('--- 600 프레임 재확인 ---')
    decode()
    save()
  end
end, emu.eventType.startFrame)

emu.log('PROBE_SCREEN_WIDTH 0.1.1 loaded  --  구조를 찍고 들어간다 + VDC 쓰기를 직접 잡는다')
