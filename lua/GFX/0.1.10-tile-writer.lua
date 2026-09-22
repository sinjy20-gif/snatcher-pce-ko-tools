-- PROBE GFX 0.1.9 -- 글자 타일을 **어느 코드가** 쓰나 (0.1.7 의 PC 읽기 수정)
--
-- ★ 순수 관측.  아무것도 안 쓴다.  화면에도 아무것도 안 그린다.
--
-- 0.1.7 이 왜 실패했나
-- --------------------
-- VDC 포트 쓰기를 63 만 회 잡았는데 PC 가 전부 -1 이었다.  `state.cpu.pc` 를
-- 짐작으로 썼는데, `emu.getState()` 는 **중첩 테이블이 아니라 점 붙은 평평한
-- 키**를 준다 (0.1.8 로 확인):
--
--     st.cpu.pc        -> nil
--     st["cpu.pc"]     -> ★이게 맞다
--
-- 오늘 이름을 짐작했다가 틀린 게 네 번째다 (CD_SUBQ 재동기 · 스프라이트 64 ·
-- 타일 플레인 배치 · 이번 것).  전부 한 번 찍어보면 끝나는 것들이었다.
--
-- 그리고 하나 더
-- --------------
-- `getState()` 는 통짜 테이블이라 **호출이 비싸다.**  0.1.7 은 쓰기마다 불렀다
-- (63 만 회).  여기서는 **64 번에 한 번만** 표본을 뜬다.  히스토그램에는 충분하다.
--
-- 같이 잡는 것
--     vdc.memAddrWrite   MAWR -- 지금 VRAM 어디에 쓰는 중인가
--                        우리 타일 구간($1110-$18CF 워드)인지 가릴 수 있다
--
-- 산출물  C:/snatcher/dump/tile_writer_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local VRAM = emu.memType.pceVideoRam

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/tile_writer_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('upload\tframe\tpc\tcount\tmawr_lo\tmawr_hi\n')

local function say(m) emu.log(m); print(m) end

local TILE_FIRST, TILE_LAST = 0x111, 0x18C
local WORD_LO, WORD_HI = TILE_FIRST * 16, TILE_LAST * 16 + 15   -- $1110-$18CF

-- ★ 0.1.9 는 표본을 SATB 갱신($60AC-$60BA, MAWR $1000-$10FF)이 다 먹었다.
--   우리 타일 구간에 쓰는 것은 전체 포트 트래픽의 0.7 % 뿐이다.
--   그래서 **MAWR 이 우리 구간일 때만** 기록하고, 타일이 바뀐 직후에만 표본을 뜬다.
local SAMPLE_EVERY = 4
local MAX_SAMPLES = 4000
local HOT_FRAMES = 150          -- 타일이 바뀌면 이만큼 동안만 표본을 뜬다

local frame = 0
local prev = {}
local hist, mawr_lo, mawr_hi = {}, {}, {}
local seen, taken = 0, 0
local active, quiet, upload = false, 0, 0

local hot = 0
emu.addMemoryCallback(function()
  if hot <= 0 then return end
  seen = seen + 1
  if seen % SAMPLE_EVERY ~= 0 or taken >= MAX_SAMPLES then return end
  local st = emu.getState()
  if st == nil then return end
  local aw = st["vdc.memAddrWrite"] or -1
  if aw < WORD_LO or aw > WORD_HI then return end      -- ★우리 구간이 아니면 버린다
  taken = taken + 1
  local pc = st["cpu.pc"] or -1
  hist[pc] = (hist[pc] or 0) + 1
  if mawr_lo[pc] == nil or aw < mawr_lo[pc] then mawr_lo[pc] = aw end
  if mawr_hi[pc] == nil or aw > mawr_hi[pc] then mawr_hi[pc] = aw end
end, emu.callbackType.write, 0x0000, 0x0003, CPU, MEM)

local function report()
  upload = upload + 1
  local pcs = {}
  for pc, n in pairs(hist) do pcs[#pcs + 1] = { pc, n } end
  table.sort(pcs, function(x, y) return x[2] > y[2] end)
  say('')
  say(('=== %d 번째 업로드 끝  f%d  --  포트 쓰기 %d 회 · 표본 %d · PC %d 종')
    :format(upload, frame, seen, taken, #pcs))
  say(('    (우리 타일 구간은 VRAM 워드 $%04X-$%04X)'):format(WORD_LO, WORD_HI))
  for i = 1, math.min(#pcs, 10) do
    local pc = pcs[i][1]
    local mark = ''
    mark = '  ★우리 타일을 쓴다'
    local line = ('  $%04X  %5d 회   MAWR $%04X-$%04X%s')
      :format(pc, pcs[i][2], mawr_lo[pc] or 0, mawr_hi[pc] or 0, mark)
    say(line)
    out:write(('%d\t%d\t%04X\t%d\t%04X\t%04X\n')
      :format(upload, frame, pc, pcs[i][2], mawr_lo[pc] or 0, mawr_hi[pc] or 0))
  end
  if #pcs == 0 then say('  ★우리 구간에 쓰는 것을 못 잡았다 -- HOT 창을 늘리거나 표본을 늘릴 것') end
  out:flush()
  hist, mawr_lo, mawr_hi = {}, {}, {}
  seen, taken = 0, 0
end

local function sample(t)
  local b = t * 32
  return (emu.read(b, VRAM) or 0) * 0x10000
       + (emu.read(b + 1, VRAM) or 0) * 0x100
       + (emu.read(b + 2, VRAM) or 0)
end

emu.addEventCallback(function()
  frame = frame + 1
  if hot > 0 then hot = hot - 1 end
  local moved = 0
  for t = TILE_FIRST, TILE_LAST do
    local v = sample(t)
    if prev[t] ~= nil and v ~= prev[t] then moved = moved + 1 end
    prev[t] = v
  end
  if moved > 0 then
    if not active then active = true; say(('★업로드 시작 f%d'):format(frame)) end
    hot = HOT_FRAMES
    quiet = 0
  elseif active then
    quiet = quiet + 1
    if quiet >= 30 then active = false; report() end
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:close(); say(''); say(('끝 -- 업로드 %d 회'):format(upload)); say('  ' .. PATH)
end, emu.eventType.scriptEnded)

say('PROBE GFX 0.1.10-tile-writer armed -- 순수 관측')
say('  헌사 화면 직전에 올릴 것.  업로드가 끝날 때마다 그 자리에서 찍는다')
say('  ' .. PATH)
