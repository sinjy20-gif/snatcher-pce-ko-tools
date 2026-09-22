-- PROBE GFX 0.1.6 -- 글자 타일을 **어느 코드가** 쓰나 (PC 를 잡는다)
--
-- ★ 순수 관측.  아무것도 안 쓴다.  화면에도 아무것도 안 그린다.
--
-- 0.1.5 에서 밝힌 것 / 못 밝힌 것
-- --------------------------------
-- ```
-- 밝혔다   CD_READ 는 범인이 아니다.  2·3 번째 업로드 직전 60 프레임에 호출이 없다
--          (마지막 CD_READ 가 546 프레임 전).  데이터는 이미 RAM 에 있고
--          게임이 자기 코드로 VDC 에 옮긴다
-- 못 밝혔다 그 "자기 코드" 가 어디인지.  VDC 포트($0002) 쓰기 콜백이 안 걸렸고,
--          보고가 scriptEnded 에만 있어서 결과를 못 봤다
-- ```
--
-- 그래서 두 곳을 고쳤다
-- --------------------
--     ① 포트가 아니라 **VRAM 자체**에 쓰기 콜백을 건다.  글자 타일 바이트 범위만
--        본다 ($2220-$319F).  블록전송이든 루프든 VRAM 이 바뀌면 잡힌다
--     ② 업로드가 끝날 때마다 **그 자리에서** 보고한다.  Stop 을 안 눌러도 된다
--
-- 무엇을 남기나
-- -------------
--     업로드 창마다  타일을 쓴 PC 히스토그램 (많이 쓴 순)
--     -> 그 PC 가 그림을 옮기는 루틴이다.  주변을 디스어셈블해 "끝나는 자리" 를
--        잡으면 그게 네이티브 훅 자리가 된다
--
-- ⚠ 그래도 안 잡히면 에뮬레이터가 VRAM 쓰기에 PC 를 안 주는 것이다.  그때는
--   실행 추적(코드 구간에 exec 콜백)으로 다시 짜야 한다.
--
-- 산출물  C:/snatcher/dump/vdc_writer_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local VRAM = emu.memType.pceVideoRam

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/vdc_writer_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('upload\tframe\tpc\tcount\n')

local function say(m) emu.log(m); print(m) end

local TILE_FIRST, TILE_LAST = 0x111, 0x18C
-- ★ 0.1.6 은 VRAM 자체에 걸었다가 **한 번도 안 잡혔다** -- 에뮬레이터가 VRAM
--   쓰기에 PC 를 안 준다.  그래서 CPU 쪽 VDC 포트로 옮긴다.  VRAM 을 바꾸려면
--   반드시 이 넷을 거치므로 여기서는 잡혀야 한다.
--       $0000 레지스터 선택 · $0001 (미사용) · $0002/$0003 데이터 포트
local BYTE_LO, BYTE_HI = 0x0000, 0x0003

local frame = 0
local prev = {}
local hist = {}
local hits = 0
local active, quiet, upload = false, 0, 0

local function pc_now()
  local st = emu.getState()
  if st == nil then return -1 end
  if st.cpu ~= nil and st.cpu.pc ~= nil then return st.cpu.pc end
  if st.pce ~= nil and st.pce.cpu ~= nil and st.pce.cpu.pc ~= nil then
    return st.pce.cpu.pc
  end
  return -1
end

emu.addMemoryCallback(function()
  hits = hits + 1
  if hits > 20000 then return end
  local pc = pc_now()
  hist[pc] = (hist[pc] or 0) + 1
end, emu.callbackType.write, BYTE_LO, BYTE_HI, CPU, MEM)

local function report()
  upload = upload + 1
  local pcs = {}
  for pc, n in pairs(hist) do pcs[#pcs + 1] = { pc, n } end
  table.sort(pcs, function(x, y) return x[2] > y[2] end)
  say('')
  say(('=== %d 번째 업로드 끝  f%d  --  VDC 포트 쓰기 %d 회 · PC %d 종')
    :format(upload, frame, hits, #pcs))
  if #pcs == 0 then
    say('  ★여기서도 못 잡았다 -- 실행 추적(exec)으로 가야 한다')
    out:write(('%d\t%d\t\t0\n'):format(upload, frame))
  end
  for i = 1, math.min(#pcs, 10) do
    local line = ('  $%04X   %6d 회'):format(pcs[i][1], pcs[i][2])
    say(line)
    out:write(('%d\t%d\t%04X\t%d\n'):format(upload, frame, pcs[i][1], pcs[i][2]))
  end
  out:flush()
  hist, hits = {}, 0
end

local function sample(t)
  local b = t * 32
  return (emu.read(b, VRAM) or 0) * 0x10000
       + (emu.read(b + 1, VRAM) or 0) * 0x100
       + (emu.read(b + 2, VRAM) or 0)
end

emu.addEventCallback(function()
  frame = frame + 1
  local moved = 0
  for t = TILE_FIRST, TILE_LAST do
    local v = sample(t)
    if prev[t] ~= nil and v ~= prev[t] then moved = moved + 1 end
    prev[t] = v
  end
  if moved > 0 then
    if not active then
      active = true
      say(('★업로드 시작 f%d'):format(frame))
    end
    quiet = 0
  elseif active then
    quiet = quiet + 1
    if quiet >= 30 then
      active = false
      report()
    end
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:close()
  say('')
  say(('끝 -- 업로드 %d 회 관측'):format(upload))
  say('  ' .. PATH)
end, emu.eventType.scriptEnded)

say('PROBE GFX 0.1.7-vdc-writer armed -- 순수 관측')
say('  헌사 화면 직전에 올릴 것.  업로드가 끝날 때마다 그 자리에서 PC 를 찍는다')
say('  ' .. PATH)
