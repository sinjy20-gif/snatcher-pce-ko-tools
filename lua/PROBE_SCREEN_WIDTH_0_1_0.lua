-- PROBE_SCREEN_WIDTH 0.1.0  --  표시 폭을 VDC 에서 직접 읽는다
--
-- 왜
-- --
-- 자막 16 글자(16 px x 16 = 256 px)를 깔았더니 스프라이트 뷰어에는 16 개가
-- 온전히 다 있는데 화면에서는 양끝이 잘린다.  즉 **표시 영역이 256 보다 좁다.**
-- 나는 256 을 가정하고 좌표를 계산해 왔다.  그 가정을 걷어낸다.
--
-- HuC6270 의 가로 타이밍 레지스터 (reg $0A HSR / $0B HDR)
--   HDW  표시 폭   = (HDW + 1) * 8 px
--   HSW  동기 폭   HDS 표시시작   HDE 표시끝
--
-- emu.getState().vdc 에 hvReg / hvLatch 로 들어온다 (0.1.0 상태덤프에서 확인).
-- 필드 이름을 모르니 vdc.hvReg 아래를 통째로 찍고, 폭으로 보이는 값을 환산한다.
--
-- 출력  로그 + C:/snatcher/dump/probe_screen_width_0_1_0_<날짜>.tsv

local frames, done = 0, false
local lines = {}
local function say(s) emu.log(s); lines[#lines+1] = s end

local function dump()
  local ok, st = pcall(emu.getState)
  if not ok or type(st) ~= 'table' or type(st.vdc) ~= 'table' then
    say('★ emu.getState().vdc 를 못 읽었다'); return
  end

  for _, group in ipairs({ 'hvReg', 'hvLatch' }) do
    local g = st.vdc[group]
    if type(g) == 'table' then
      say('--- vdc.' .. group .. ' ---')
      local keys = {}
      for k in pairs(g) do keys[#keys+1] = tostring(k) end
      table.sort(keys)
      for _, k in ipairs(keys) do
        local v = g[k]
        if type(v) ~= 'table' then
          local extra = ''
          local lk = k:lower()
          if lk:find('width') or lk:find('hdw') or lk:find('display') then
            if type(v) == 'number' then
              extra = string.format('   -> %d px  (16 px 글자 %d 자)',
                                    (v + 1) * 8, math.floor((v + 1) * 8 / 16))
            end
          end
          say(string.format('    %s = %s%s', k, tostring(v), extra))
        end
      end
    else
      say('--- vdc.' .. group .. ' 없음 ---')
    end
  end

  -- 세로도 같이 본다 (자막 Y 를 정할 때 필요하다)
  say('--- vdc 최상위 중 폭/높이로 보이는 것 ---')
  local keys = {}
  for k in pairs(st.vdc) do keys[#keys+1] = tostring(k) end
  table.sort(keys)
  for _, k in ipairs(keys) do
    local v = st.vdc[k]
    local lk = k:lower()
    if type(v) ~= 'table' and (lk:find('width') or lk:find('height')
       or lk:find('column') or lk:find('row') or lk:find('scroll')) then
      say(string.format('    %s = %s', k, tostring(v)))
    end
  end

  local f = io.open(string.format('C:/snatcher/dump/probe_screen_width_0_1_0_%s.tsv',
                                  os.date('%Y%m%d_%H%M%S')), 'w')
  if f then
    f:write('line\n')
    for _, s in ipairs(lines) do f:write(s .. '\n') end
    f:close()
  end
end

emu.addEventCallback(function()
  frames = frames + 1
  -- 부팅 직후가 아니라 실제 장면이 선 뒤에 읽는다
  if not done and frames >= 120 then done = true; dump() end
end, emu.eventType.startFrame)

emu.log('PROBE_SCREEN_WIDTH 0.1.0 loaded  --  대사 장면에서 120 프레임 뒤 한 번 찍는다')
