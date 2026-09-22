-- PROBE_SPRITE_BUDGET 0.1.0  --  순수 관측.  아무것도 안 쓴다
--
-- 왜
-- --
-- 0.1.5 가 "한 스캔라인에 21 스프라이트 / 23 칸" 을 셌고 나는 그걸로
-- "16 글자는 안 된다 · 한 줄 9 글자" 라고 결론냈다.  둘 다 근거가 약하다.
--
--   1  길리언 초상이 없던 것을 드롭아웃 증거로 들었는데, 그 장면에서
--      원래 안 나올 시간이었다.  드롭아웃 관측이 아니었다.
--   2  나중 스크린샷에서 초상도 자막도 멀쩡하고, 초상이 가린 자리만
--      글자가 없다.  그건 버려진 게 아니라 **가려진** 것이다
--      (PCE 는 슬롯 번호가 낮을수록 앞.  우리는 게임 뒤에 밀어서 항상 뒤다).
--   3  0.1.5 는 Y 만 겹치면 다 셌다.  게임이 안 쓰는 스프라이트를 화면 밖
--      X 에 세워두면 그것까지 칸으로 잡힌다.  23 은 부풀었을 수 있다.
--
-- **23 칸을 셌다** 와 **VDC 가 실제로 버렸다** 사이가 비어 있다.
-- 이 판은 그 사이를 메운다.  패치를 하나도 안 하므로 위험이 0 이다.
--
-- 재는 것
-- ------
--   A  칸 수를 두 가지로 센다
--        raw    -- 0.1.5 와 같은 방식 (Y 만 겹치면 센다)
--        culled -- 화면 밖 X 를 뺀 것.  이쪽이 진짜 페치 부담에 가깝다
--      둘 차이가 크면 0.1.5 의 23 은 허수였다는 뜻이다.
--   B  VDC 상태에 스프라이트 오버플로 플래그가 있는지 찾는다.
--      emu.getState() 의 키를 한 번 통째로 찍는다 -- 있으면 그게 바닥값이다.
--   C  화면 240 줄 전체를 16 줄 밴드로 묶어 게임 점유 프로파일을 낸다.
--      자막 줄을 어디에 놓을 수 있고 몇 글자가 들어가는지가 여기서 나온다.
--   D  자막이 게임보다 앞에 설 수 있는지: 게임이 쓰는 최저/최고 슬롯을 본다.
--
-- 출력  로그 + C:/snatcher/dump/probe_sprite_budget_0_1_0_<날짜>.tsv (300 프레임마다)

local VRAM = emu.memType.pceVideoRam
local SATB_BYTE = 0x2000
local CGY = { [0] = 16, [1] = 32, [2] = 64, [3] = 64 }
local LIMIT = 16
local SCREEN_H, BAND = 240, 16
local BANDS = SCREEN_H / BAND

local frames, state_dumped = 0, false
local peak_raw, peak_culled = {}, {}       -- 밴드별 최대
local live_lo, live_hi, live_max = 64, -1, 0
local lines = {}
local function say(s) emu.log(s); lines[#lines+1] = s end
for b = 0, BANDS - 1 do peak_raw[b] = 0; peak_culled[b] = 0 end

local function rb(a) return emu.read(a, VRAM) or 0 end
local function vw(o) return rb(o) + rb(o + 1) * 256 end

-- emu.getState() 가 무엇을 주는지 한 번만 통째로 본다.
local function dump_state()
  local ok, st = pcall(emu.getState)
  if not ok or type(st) ~= 'table' then
    say('★ emu.getState() 를 못 읽었다'); return
  end
  local function walk(t, prefix, depth)
    if depth > 2 then return end
    local keys = {}
    for k in pairs(t) do keys[#keys+1] = tostring(k) end
    table.sort(keys)
    for _, k in ipairs(keys) do
      local v = t[k]
      local path = prefix == '' and k or (prefix .. '.' .. k)
      if type(v) == 'table' then
        walk(v, path, depth + 1)
      else
        -- 스프라이트/오버플로 관련만 추린다
        local lk = path:lower()
        if lk:find('sprite') or lk:find('overflow') or lk:find('collis')
           or lk:find('status') or lk:find('satb') then
          say(string.format('    %s = %s', path, tostring(v)))
        end
      end
    end
  end
  say('--- emu.getState() 중 스프라이트/상태 관련 키 ---')
  walk(st, '', 0)
  say('--- 끝 ---')
end

-- SATB 64 칸을 디코드한다.  살아있는 엔트리만 돌려준다.
local function decode()
  local live = {}
  for s = 0, 63 do
    local o = SATB_BYTE + s * 8
    local y, x, p, a = vw(o), vw(o + 2), vw(o + 4), vw(o + 6)
    if not (y == 0 and x == 0 and p == 0 and a == 0) then
      local wid = (math.floor(a / 256) % 2 == 1) and 32 or 16
      live[#live+1] = {
        slot = s,
        top  = y - 64,
        left = x - 32,
        hgt  = CGY[math.floor(a / 4096) % 4],
        wid  = wid,
        cells = wid / 16,
      }
    end
  end
  return live
end

emu.addEventCallback(function()
  frames = frames + 1
  if not state_dumped then state_dumped = true; dump_state() end

  local live = decode()
  if #live > live_max then live_max = #live end
  for _, e in ipairs(live) do
    if e.slot < live_lo then live_lo = e.slot end
    if e.slot > live_hi then live_hi = e.slot end
  end

  -- 스캔라인마다 raw / culled 칸 수
  for sy = 0, SCREEN_H - 1 do
    local raw, culled = 0, 0
    for _, e in ipairs(live) do
      if sy >= e.top and sy < e.top + e.hgt then
        raw = raw + e.cells
        -- 화면 밖 X 는 뺀다: 오른쪽 끝이 0 보다 작거나 왼쪽 끝이 256 이상
        if e.left + e.wid > 0 and e.left < 256 then culled = culled + e.cells end
      end
    end
    local b = math.floor(sy / BAND)
    if raw    > peak_raw[b]    then peak_raw[b]    = raw    end
    if culled > peak_culled[b] then peak_culled[b] = culled end
  end

  if frames % 300 == 0 then
    say(string.format('--- %d 프레임 --- 살아있는 엔트리 최대 %d · 슬롯 %d..%d',
                      frames, live_max, live_lo, live_hi))
    say('    밴드   화면Y      raw   culled   자막여유(16-culled)')
    for b = 0, BANDS - 1 do
      if peak_raw[b] > 0 then
        say(string.format('    %2d    %3d-%3d    %3d     %3d        %3d %s',
              b, b * BAND, b * BAND + BAND - 1, peak_raw[b], peak_culled[b],
              LIMIT - peak_culled[b],
              peak_culled[b] > LIMIT and '★ 이미 초과' or ''))
      end
    end
    local name = string.format('C:/snatcher/dump/probe_sprite_budget_0_1_0_%s.tsv',
                               os.date('%Y%m%d_%H%M%S'))
    local f = io.open(name, 'w')
    if f then
      f:write('line\n')
      for _, s in ipairs(lines) do f:write(s .. '\n') end
      f:close(); emu.log('-> ' .. name)
    end
  end
end, emu.eventType.startFrame)

emu.log('PROBE_SPRITE_BUDGET 0.1.0 loaded  --  아무것도 안 쓴다.  게임만 본다')
emu.log('  대사 장면 · UI 장면 · 이동 장면을 두루 지나갈 것')
