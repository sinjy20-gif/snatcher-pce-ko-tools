-- SUB 0.4.68-satb -- 자막 줄의 스프라이트 항목을 그대로 덤프한다.  읽기 전용
--
-- ── 여기까지 확정된 것 ───────────────────────────────────────────────────
--
--   0.4.65   업로드 후 90프레임 동안 블록 1 word 도 안 변함 (침범 0)
--   0.4.66   빈 슬롯 31~34 개 · 스캔라인 초과는 정상 사례에도 뜬다
--   0.4.67   블록 1216 word 를 비워도 깨짐이 그대로
--   뷰어     우리 글리프는 정상.  그 **뒤에 붙은 별개 타일**이 쓰레기이고,
--            이어서 게임 초상화 패턴이 보인다
--
-- 넷을 합치면 하나로 모인다: **여분 스프라이트가 우리 블록 밖을 가리킨다.**
-- 글리프 데이터 문제가 아니라 스프라이트 목록 문제다.
--
-- ── 그래서 무엇을 찍나 ───────────────────────────────────────────────────
--
-- count_ok 에서 base 를 잡고, 전환 직후 여러 프레임에 걸쳐 SATB 를 훑는다.
-- 자막 줄(우리 스프라이트가 있는 y)에 놓인 스프라이트를 전부 적는다:
--
--     slot  y  x  pattern -> VRAM 주소  팔레트  크기  우리것?
--
-- 우리 줄에 있으면서 패턴 주소가 [base, base+1216) 밖이면 ★ 로 찍는다.
-- 그 주소가 어디를 가리키는지가 곧 역추적의 출발점이다.
--
-- 짧게 스치는 프레임이 있으므로 한 프레임만 보지 않는다 (WINDOW 프레임).
--
-- ── 쓰는 법 ──────────────────────────────────────────────────────────────
--
--     이 파일 하나만 로드.  안에서 0.4.64 를 부른다.
--     다른 스택 위에서 보려면 아래 dofile 한 줄만 바꾸면 된다.
--
--     dump/satb_0_4_68_<시각>.tsv

local CHILD = rawget(_G, 'SUB_SATB_CHILD') or
              'C:/snatcher/lua/SUB/0.4.64-fixedbase.lua'
dofile(CHILD)

local MEM  = emu.memType.pceMemory
local VRAM = emu.memType.pceVideoRam
local CPU  = emu.cpuType.pce

local ENGINE   = 0x5B80
local COUNT_OK = ENGINE + 118
local SELECTOR = ENGINE + 345
local VRAM_LO, VRAM_HI = 144, 146
local NEED = 19 * 0x40
local SATB_WORD = 0x1000
local WINDOW = 8                       -- 전환 후 이만큼 프레임을 훑는다

local stamp = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/satb_0_4_68_' .. stamp .. '.tsv'
local out = io.open(OUT, 'w')
if out then
  out:write('key\tbase\tframe\tslot\ty\tx\tpattern\taddr\tpal\twide\ttall\tmine\n')
  out:flush()
end

local function rw(w)
  local at = w * 2
  return (emu.read(at, VRAM) or 0) | ((emu.read(at + 1, VRAM) or 0) << 8)
end

local function keyHex()
  local t = {}
  for i = 0, 5 do
    t[i + 1] = string.format('%02X', emu.read(SELECTOR + i, MEM) or 0)
  end
  return table.concat(t)
end

local watch = nil
local strays, dumps = 0, 0

emu.addMemoryCallback(function()
  watch = {
    base = (emu.read(ENGINE + VRAM_LO, MEM) or 0) |
           ((emu.read(ENGINE + VRAM_HI, MEM) or 0) << 8),
    key = keyHex(),
    age = 0,
    told = false,
  }
end, emu.callbackType.exec, COUNT_OK, COUNT_OK, CPU, MEM)

emu.addEventCallback(function()
  local w = watch
  if not w then return end
  w.age = w.age + 1
  if w.age > WINDOW then watch = nil; return end

  local base = w.base
  -- 1) 우리 스프라이트가 놓인 y 를 찾는다.
  local rows = {}
  local list = {}
  for slot = 0, 63 do
    local at = SATB_WORD + slot * 4
    local y, x = rw(at), rw(at + 1)
    local pattern, attr = rw(at + 2), rw(at + 3)
    if not (y == 0 and x == 0 and pattern == 0 and attr == 0) then
      local addr = (pattern & 0x07FF) << 5
      local mine = addr >= base and addr < base + NEED
      list[#list + 1] = { slot = slot, y = y, x = x, pattern = pattern,
                          addr = addr, attr = attr, mine = mine }
      if mine then rows[y] = true end
    end
  end
  if next(rows) == nil then return end

  -- 2) 그 y 에 놓인 스프라이트를 전부 적는다.  블록 밖을 가리키면 ★.
  local stray = {}
  for _, s in ipairs(list) do
    if rows[s.y] then
      local pal = s.attr & 0x0F
      local wide = ((s.attr & 0x0100) ~= 0) and 2 or 1
      local hc = (s.attr >> 12) & 0x03
      local tall = (hc == 0) and 1 or ((hc == 1) and 2 or 4)
      if out then
        out:write(string.format('%s\t%04X\t%d\t%d\t%d\t%d\t%04X\t%04X\t%X\t%d\t%d\t%s\n',
          w.key, base, w.age, s.slot, s.y, s.x, s.pattern, s.addr, pal, wide, tall,
          s.mine and 'Y' or 'N'))
      end
      if not s.mine then
        stray[#stray + 1] = string.format('slot%d x%d $%04X pal%X', s.slot, s.x, s.addr, pal)
      end
    end
  end
  if out then out:flush() end
  dumps = dumps + 1

  if #stray > 0 and not w.told then
    w.told = true
    strays = strays + 1
    emu.log(string.format('SUB 0.4.68 ★ %s base $%04X +%df · 자막 줄에 블록 밖 스프라이트 %d개',
                          w.key, base, w.age, #stray))
    for i = 1, math.min(#stray, 8) do emu.log('      ' .. stray[i]) end
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if out then out:close(); out = nil end
  emu.log(string.format('SUB 0.4.68 끝 -- 덤프 %d프레임 · 블록 밖 발견 %d회', dumps, strays))
  emu.log('  ' .. OUT)
end, emu.eventType.scriptEnded)

emu.log('SUB 0.4.68-satb armed -- 자막 줄 스프라이트 덤프 (쓰기 0)')
emu.log(string.format('  전환 후 %d프레임을 훑는다 · 우리 블록 밖을 가리키면 ★', WINDOW))
emu.log('  ' .. OUT)
