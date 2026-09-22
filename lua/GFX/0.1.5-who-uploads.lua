-- PROBE GFX 0.1.5 -- 그림을 **누가** VRAM 에 올리나
--
-- ★ 순수 관측.  아무것도 안 쓴다.  화면에도 아무것도 안 그린다.
--
-- 왜
-- --
-- 네이티브 주입의 훅 자리를 정해야 한다.  매 프레임 폴링은 비싸고($FEC4 는 이미
-- 자막 디스패처가 쓴다), **그림을 올리는 그 자리에 걸면** 공짜다.
--
-- 그리고 이 프로젝트엔 이미 그런 자리가 있다:
--
--     $E009 (BIOS 점프테이블의 CD_READ) -> boot_hook  (0.4.6.11 이 심었다)
--     boot_hook 의 ordinary_read 갈래가 `JSR ORIGINAL_CD_READ($EC05)` 로
--     원본을 부르고 **돌아온다**.  즉 모든 CD 읽기 직후 제어가 우리에게 온다.
--
-- 그래서 갈림길은 하나다:
--
--     CD_READ 가 VRAM 으로 직접 읽는다        -> 그 훅에서 바로 잡힌다.  끝
--     게임이 RAM 으로 읽고 자기 코드로 옮긴다  -> 그 훅은 못 본다.  진짜 주인을 찾아야 한다
--
-- ⚠ "BIOS CD_READ 는 VRAM 목적지 모드가 있다" 는 **이름만 아는 사실**이다.
--   오늘만 이름을 믿었다가 두 번 틀렸다 (CD_SUBQ 재동기 · 스프라이트 64 개).
--   그래서 판정을 실측에 맡긴다.
--
-- 무엇을 남기나
-- -------------
--     CD_READ 호출     프레임 · A/X/Y · 제로페이지 스냅샷
--                      ★파라미터 자리를 모르므로 zp 를 통째로 떠서 나중에 가른다
--     VDC 포트 쓰기    타일이 바뀌는 프레임에 $0002 에 쓰는 **PC** 를 표본으로
--                      -> 진짜 쓰는 루틴이 어디인지 (주소가 아니라 루틴을 찾는다)
--     업로드 창        타일 구간이 바뀐 프레임 (0.1.4 와 같은 방식)
--
-- 읽는 법
--     업로드 창 직전에 CD_READ 가 있다   -> CD_READ 경로다.  zp 에서 목적지를 가른다
--     없고 VDC PC 만 잡힌다              -> 게임 코드가 옮긴다.  그 PC 를 디스어셈블할 것
--
-- 산출물  C:/snatcher/dump/who_uploads_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local VRAM = emu.memType.pceVideoRam

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/who_uploads_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tkind\tdetail\n')

local function say(m) emu.log(m); print(m) end

local CD_READ_TABLE = 0xE009      -- BIOS 점프테이블 (우리가 boot_hook 으로 돌렸다)
local ORIGINAL_CD_READ = 0xEC05   -- 원본 루틴
local VDC_DATA = 0x0002           -- VDC 데이터 포트 (lo)

local TILE_FIRST, TILE_LAST = 0x111, 0x18C
local ZP_LO, ZP_HI = 0x20E0, 0x20FF   -- CD_READ 파라미터가 있을 만한 제로페이지 끝

local frame = 0
local prev = {}
local upload_frames = {}
local pending = {}                -- 최근 CD_READ 호출 (프레임 -> 설명)
local vdc_pc = {}                 -- PC -> 횟수
local vdc_samples = 0
local watching = false

local function zpsnap()
  local t = {}
  for a = ZP_LO, ZP_HI do t[#t + 1] = ('%02X'):format(emu.read(a, MEM, false) or 0) end
  return table.concat(t, ' ')
end

local function logcall(name)
  local st = emu.getState()
  local a, x, y = 0, 0, 0
  if st ~= nil and st.cpu ~= nil then
    a, x, y = st.cpu.a or 0, st.cpu.x or 0, st.cpu.y or 0
  end
  local detail = ('%s A=%02X X=%02X Y=%02X  zp[%04X-%04X]= %s')
    :format(name, a, x, y, ZP_LO, ZP_HI, zpsnap())
  pending[#pending + 1] = { frame, detail }
  out:write(('%d\tCDREAD\t%s\n'):format(frame, detail))
  out:flush()
  say(('  f%-7d ★%s  A=%02X X=%02X Y=%02X'):format(frame, name, a, x, y))
end

emu.addMemoryCallback(function() logcall('CD_READ table $E009') end,
                      emu.callbackType.exec, CD_READ_TABLE, CD_READ_TABLE, CPU, MEM)
emu.addMemoryCallback(function() logcall('original $EC05') end,
                      emu.callbackType.exec, ORIGINAL_CD_READ, ORIGINAL_CD_READ, CPU, MEM)

-- VDC 데이터 포트에 쓰는 주인을 찾는다.  표본만 모은다 (업로드는 수천 번 쓴다).
emu.addMemoryCallback(function()
  if not watching or vdc_samples >= 4000 then return end
  vdc_samples = vdc_samples + 1
  local st = emu.getState()
  local pc = (st ~= nil and st.cpu ~= nil and st.cpu.pc) or 0
  vdc_pc[pc] = (vdc_pc[pc] or 0) + 1
end, emu.callbackType.write, VDC_DATA, VDC_DATA, CPU, MEM)

local function sample(t)
  local b = t * 32
  return (emu.read(b, VRAM) or 0) * 0x10000
       + (emu.read(b + 1, VRAM) or 0) * 0x100
       + (emu.read(b + 2, VRAM) or 0)
end

emu.addEventCallback(function()
  frame = frame + 1
  watching = true
  local moved = 0
  for t = TILE_FIRST, TILE_LAST do
    local v = sample(t)
    if prev[t] ~= nil and v ~= prev[t] then moved = moved + 1 end
    prev[t] = v
  end
  if moved > 0 then
    upload_frames[#upload_frames + 1] = frame
    out:write(('%d\tTILES\t바뀐 타일 %d\n'):format(frame, moved))
    say(('  f%-7d 타일 %d 개 바뀜'):format(frame, moved))
    -- 이 업로드 직전 60 프레임 안의 CD_READ 를 붙여 준다
    for _, p in ipairs(pending) do
      if frame - p[1] <= 60 then
        say(('      <- f%d 에 %s'):format(p[1], p[2]:sub(1, 40)))
      end
    end
    pending = {}
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  say('')
  say('끝')
  say(('  업로드가 있던 프레임 %d 개'):format(#upload_frames))
  local pcs = {}
  for pc, n in pairs(vdc_pc) do pcs[#pcs + 1] = { pc, n } end
  table.sort(pcs, function(x, y) return x[2] > y[2] end)
  say(('  VDC $0002 에 쓴 PC %d 종 (표본 %d 회)'):format(#pcs, vdc_samples))
  out:write('#\n')
  for i = 1, math.min(#pcs, 12) do
    local line = ('  $%04X  %d 회'):format(pcs[i][1], pcs[i][2])
    say(line); out:write('# VDC_PC' .. line .. '\n')
  end
  if #pcs == 0 then
    say('  ★VDC 포트 쓰기를 한 번도 못 잡았다 -- 블록전송(TIA)이라 콜백이 안 걸릴 수 있다')
  end
  out:close()
  say('')
  say('  ' .. PATH)
end, emu.eventType.scriptEnded)

say('PROBE GFX 0.1.5-who-uploads armed -- 순수 관측')
say('  헌사 화면 **직전**에 올릴 것.  업로드마다 그 직전 CD_READ 를 같이 찍는다')
say('  ' .. PATH)
