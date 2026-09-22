-- PROBE_BAT_PERSIST 0.1.0
--
-- 무엇을 재나
-- ------------
-- 1  BAT 이 VRAM 어디에 있나 (V12 는 바이트 $1000-$2FFF / 64x64 라고 적어뒀다.
--    7 월 값이라 지금도 맞는지 확인이 필요하다)
-- 2  거기에 우리가 한 칸 써넣으면 게임이 얼마 만에 덮어쓰나
--
-- 왜 필요한가
--   자막을 BAT 으로 띄우려면, 한 번만 쓰면 되는지 매 프레임 다시 써야 하는지
--   알아야 한다.  V12 는 "계속 그려야 했다" 는 인상을 남겼는데 주기는 안 쟀다.
--
-- 방법
--   빈 타일(가장 흔한 값)이 들어 있는 화면 하단 칸을 하나 골라 표식을 쓴다.
--   매 프레임 읽어서 언제 사라지는지 센다.  사라지면 다시 쓴다.
--   게임 화면을 건드리지만 한 칸뿐이고, 원래 값으로 되돌리며 끝낸다.
--
-- 판정
--   생존 프레임 수가 크다 (수백+)  -> 한 번만 쓰면 된다.  자막이 싸진다
--   생존이 1~2 프레임             -> 매 프레임 다시 써야 한다.  IRQ 부담 계산 필요
--   아예 안 써짐                  -> BAT 주소가 틀렸다.  후보를 다시 잡아야 한다
--
-- 출력  C:/snatcher/dump/probe_bat_persist_0_1_0_<날짜>.tsv

local vram = emu.memType.pceVideoRam
local function vr(a) return emu.read(a, vram) or 0 end
local function vw(a, v) emu.write(a, v, vram) end
local function vword(a) return vr(a) + vr(a + 1) * 0x100 end
local function vwword(a, v) vw(a, v % 0x100); vw(a + 1, math.floor(v / 0x100) % 0x100) end

-- BAT 후보.  바이트 주소, (베이스, 폭, 높이)
local CANDIDATES = {
  { 0x1000, 64, 64 }, { 0x1000, 64, 32 },
  { 0x0000, 64, 64 }, { 0x0000, 64, 32 }, { 0x0000, 32, 32 },
  { 0x2000, 64, 64 },
}

local base, cols, rows = nil, nil, nil
local blank, cell, original = nil, nil, nil
local MARKER = nil

local frames, survived, deaths, totalLife = 0, 0, 0, 0
local lives = {}
local writtenAt = nil
local ready = false

-- 가장 흔한 값이 얼마나 지배적인지로 BAT 을 고른다
local function score(b, w, h)
  local seen, best, bestv = {}, 0, 0
  for i = 0, w * h - 1 do
    local v = vword(b + i * 2) % 0x1000
    seen[v] = (seen[v] or 0) + 1
    if seen[v] > best then best, bestv = seen[v], v end
  end
  return best / (w * h), bestv
end

local function pick()
  local bestFrac = 0
  for _, c in ipairs(CANDIDATES) do
    local frac, v = score(c[1], c[2], c[3])
    emu.log(string.format('  후보 $%04X %dx%d  최빈값 #%03X 비율 %.0f%%',
            c[1], c[2], c[3], v, frac * 100))
    if frac > bestFrac and frac < 0.99 then
      bestFrac, base, cols, rows, blank = frac, c[1], c[2], c[3], v
    end
  end
  if base == nil then return false end
  -- 화면 하단(가시 28줄 기준 20~27줄)에서 빈 타일 칸을 하나 고른다
  for r = 20, math.min(rows, 28) - 1 do
    for c = 4, 27 do
      local a = base + (r * cols + c) * 2
      if vword(a) % 0x1000 == blank then
        cell, original = a, vword(a)
        MARKER = (blank + 1) % 0x1000
        emu.log(string.format('  선택 BAT $%04X %dx%d · 빈타일 #%03X · 시험칸 %d행 %d열 ($%04X)',
                base, cols, rows, blank, r, c, cell))
        return true
      end
    end
  end
  return false
end

local function onFrame()
  frames = frames + 1
  if not ready then
    if frames < 120 then return end            -- 화면이 자리잡을 시간을 준다
    ready = pick()
    if not ready then
      if frames % 300 == 0 then emu.log('  아직 BAT 후보를 못 정했다 -- 대사 화면으로 가볼 것') end
      return
    end
  end
  if cell == nil then return end
  local cur = vword(cell) % 0x1000
  if writtenAt == nil then
    vwword(cell, (original - (original % 0x1000)) + MARKER)
    writtenAt = frames
  elseif cur ~= MARKER then
    local life = frames - writtenAt
    deaths = deaths + 1
    totalLife = totalLife + life
    if #lives < 200 then lives[#lives+1] = life end
    vwword(cell, (original - (original % 0x1000)) + MARKER)
    writtenAt = frames
  else
    survived = survived + 1
  end
end

local function save()
  if cell ~= nil and original ~= nil then vwword(cell, original) end   -- 원복
  local name = string.format('C:/snatcher/dump/probe_bat_persist_0_1_0_%s.tsv',
                             os.date('%Y%m%d_%H%M%S'))
  local f = io.open(name, 'w')
  if not f then emu.log('저장 실패: ' .. name) return end
  f:write('kind\ta\tb\tc\n')
  f:write(string.format('BAT\t%s\t%s\t%s\n',
          base and string.format('%04X', base) or 'none', cols or 0, rows or 0))
  f:write(string.format('CELL\t%s\t%03X\t%d\n',
          cell and string.format('%04X', cell) or 'none', blank or 0, frames))
  for _, l in ipairs(lives) do f:write(string.format('LIFE\t%d\t\t\n', l)) end
  local avg = deaths > 0 and (totalLife / deaths) or 0
  f:write(string.format('TOTAL\t%d\t%d\t%.1f\n', survived, deaths, avg))
  f:close()
  emu.log('PROBE_BAT_PERSIST 0.1.0 -> ' .. name)
  if base == nil then
    emu.log('  ★ BAT 을 못 찾았다 -- 후보 주소를 다시 잡아야 한다')
  elseif deaths == 0 then
    emu.log(string.format('  ★ 한 번도 안 덮였다 (%d 프레임 생존) -- 한 번만 쓰면 된다', survived))
  else
    emu.log(string.format('  ★ %d 회 덮였다 · 평균 생존 %.1f 프레임', deaths, avg))
  end
end

emu.addEventCallback(onFrame, emu.eventType.startFrame)
emu.addEventCallback(save, emu.eventType.scriptEnded)
emu.log('PROBE_BAT_PERSIST 0.1.0 loaded')
emu.log('  대사 화면에서 시작할 것.  화면 아래 어딘가 타일 한 칸이 바뀐다 (끝나면 원복)')
