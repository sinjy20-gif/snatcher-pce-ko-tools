-- PROBE_AREA_ID 0.1.0  --  장소 ID 를 들고 있는 주소를 찾는다
--
-- 왜
-- --
-- 마스터의 `pack` 열이 **장소**다 (74 본부 · 75 국장실 · 76 컴퓨터실 ·
-- 6D 주차장 · 71 시내 · 72 장의 환경 A ...).  값은 6D~79 의 13 개.
--
-- 팩을 장소별로 쪼개 필요할 때만 실으려면 런타임이 **"지금 어느 장소인가"** 를
-- 알아야 한다.  게임 안에 그 값을 들고 있는 자리가 있을 것이다.  그것을 찾는다.
--
-- 어떻게
-- ------
-- 입력을 안 받는다.  그냥 켜 두고 **장소를 두세 곳 옮겨 다니면** 된다.
--
--   1  작업 RAM 을 훑어 값이 6D~79 안에 드는 주소를 모은다
--   2  그 주소가 시간이 지나며 **그 범위 안에서 다른 값으로 바뀌면** 후보다
--   3  장소를 옮길 때마다 후보가 걸러진다
--
-- 우연히 그 범위에 드는 바이트는 많지만, **장소를 옮길 때마다 정확히 그 장소의
-- 팩 번호로 바뀌는** 주소는 몇 개 없다.
--
-- 덤으로 MPR 8 개를 같이 찍는다.  pack 값이 그 장소 오버레이의 뱅크 번호일
-- 수도 있어서다 (6D~79 가 연속인 것이 뱅크처럼 보인다).  그러면 MPR 만 보면
-- 되므로 제일 싸다.
--
-- 보고는 30 초마다 파일에 쌓인다.  Stop 안 눌러도 된다.
--
-- 쓰는 법
-- -------
--   이것만 올린다 (자막 프로브 같이 안 켜도 된다)
--   본부 -> 주차장 -> 시내 처럼 **장소를 세 곳쯤** 옮겨 다닌다
--   각 장소에서 10 초쯤 머문다
--   "됐다" 하면 파일을 본다

local MEM = emu.memType.pceMemory

-- 작업 RAM.  MPR1 = $F8 이 여기 실린다 (제로페이지 $2000-$20FF 포함)
local SCAN_LO, SCAN_HI = 0x2000, 0x3FFF
-- 마스터에서 실제로 나온 pack 값 13 개
local PACK_LO, PACK_HI = 0x6D, 0x79
local SCAN_EVERY = 30          -- 프레임.  8 KB 를 매 프레임 훑을 필요는 없다

local STAMP = os.date('%Y%m%d_%H%M%S')
local REPORT = 'C:/snatcher/dump/probe_area_id_' .. STAMP .. '.txt'
local MPRLOG = 'C:/snatcher/dump/probe_area_mpr_' .. STAMP .. '.tsv'

local frames = 0
local seen = {}                -- 주소 -> { [값] = 처음 본 프레임 }
local nseen = 0
local mpr_rows = {}
local mpr_prev = nil
local lines = {}

local function say(s) emu.log(s); lines[#lines + 1] = s end

local function mpr_now()
  local st = emu.getState()
  local out = {}
  for i = 0, 7 do
    local v = st[string.format('memoryManager.mpr[%d]', i)]
    out[#out + 1] = string.format('%02X', math.floor(v or 0))
  end
  return table.concat(out, ' ')
end

-- ---------------------------------------------------------------- 훑기
local function scan()
  for a = SCAN_LO, SCAN_HI do
    local v = emu.read(a, MEM)
    if v ~= nil and v >= PACK_LO and v <= PACK_HI then
      local slot = seen[a]
      if slot == nil then
        slot = {}
        seen[a] = slot
        nseen = nseen + 1
      end
      if slot[v] == nil then
        slot[v] = frames
      end
    end
  end
end

-- ---------------------------------------------------------------- 보고
local function count_values(slot)
  local n = 0
  for _ in pairs(slot) do n = n + 1 end
  return n
end

local function write_report()
  local ranked = {}
  for a, slot in pairs(seen) do
    local n = count_values(slot)
    if n >= 2 then ranked[#ranked + 1] = { a = a, n = n, slot = slot } end
  end
  table.sort(ranked, function(x, y) return x.n > y.n end)

  local f = io.open(REPORT, 'w')
  if f == nil then return end
  f:write(string.format('== PROBE_AREA_ID == %d 프레임 (%.1f 분)\n',
    frames, frames / 3600))
  f:write(string.format('훑은 자리 $%04X-$%04X · 값 범위 $%02X-$%02X\n',
    SCAN_LO, SCAN_HI, PACK_LO, PACK_HI))
  f:write(string.format('범위 안 값을 가진 적 있는 주소 %d 개\n', nseen))
  f:write(string.format('그중 **여러 값**을 오간 주소 %d 개  <- 이게 후보다\n\n',
    #ranked))
  f:write('주소     값개수  본 값들 (값@처음본프레임)\n')
  for i = 1, math.min(60, #ranked) do
    local r = ranked[i]
    local parts = {}
    local ks = {}
    for v in pairs(r.slot) do ks[#ks + 1] = v end
    table.sort(ks)
    for _, v in ipairs(ks) do
      parts[#parts + 1] = string.format('%02X@%d', v, r.slot[v])
    end
    f:write(string.format('$%04X   %4d    %s\n', r.a, r.n,
      table.concat(parts, ' · ')))
  end
  if #ranked == 0 then
    f:write('\n(아직 없다.  장소를 두 곳 이상 옮겨 다녀야 후보가 생긴다)\n')
  end
  f:write('\n읽는 법\n')
  f:write('  값개수가 클수록 여러 장소를 따라다닌 것이다.\n')
  f:write('  실제로 간 장소의 pack 번호와 순서가 맞는 주소가 정답이다.\n')
  f:write('  (74 본부 · 75 국장실 · 76 컴퓨터실 · 6D 주차장 · 71 시내 · 72 장의 환경 A)\n')
  f:close()

  local g = io.open(MPRLOG, 'w')
  if g ~= nil then
    g:write('frame\tmpr0\tmpr1\tmpr2\tmpr3\tmpr4\tmpr5\tmpr6\tmpr7\n')
    for _, r in ipairs(mpr_rows) do g:write(r .. '\n') end
    g:close()
  end
end

-- ---------------------------------------------------------------- 프레임
emu.addEventCallback(function()
  frames = frames + 1

  local m = mpr_now()
  if m ~= mpr_prev then
    mpr_prev = m
    mpr_rows[#mpr_rows + 1] = string.format('%d\t%s', frames, m:gsub(' ', '\t'))
    if #mpr_rows <= 40 then
      say(string.format('[%d] MPR %s', frames, m))
    end
  end

  if frames % SCAN_EVERY == 0 then scan() end

  if frames % 1800 == 0 then
    write_report()
    local n = 0
    for _, slot in pairs(seen) do
      if count_values(slot) >= 2 then n = n + 1 end
    end
    say(string.format('--- %.0f 분 --- 후보 %d 개 · 범위값 주소 %d 개',
      frames / 3600, n, nseen))
  end

  -- 화면에도 띄운다
  local n = 0
  for _, slot in pairs(seen) do
    if count_values(slot) >= 2 then n = n + 1 end
  end
  emu.drawString(4, 4, string.format('장소ID 후보 %d 개 · 범위값 %d 개', n, nseen),
    0xFFFFFF, 0x80000000, 1)
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  write_report()
  emu.log('보고 -> ' .. REPORT)
end, emu.eventType.scriptEnded)

emu.log('PROBE_AREA_ID 0.1.0 loaded  --  아무것도 안 쓴다')
emu.log('  ★ 장소를 두세 곳 옮겨 다닐 것 (본부 -> 주차장 -> 시내)')
emu.log('  ★ 각 장소에서 10 초쯤 머물 것.  Stop 안 눌러도 30 초마다 파일에 쌓인다')
emu.log('  보고 -> ' .. REPORT)
emu.log('  MPR  -> ' .. MPRLOG)
