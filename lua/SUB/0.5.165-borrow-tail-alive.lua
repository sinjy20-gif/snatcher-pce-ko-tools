-- SUB 0.5.165 -- 빌린 RAM 꼬리($5DE7-$5FFF)가 CD-DA 중에 죽어 있나
--
-- ★ 순수 관측.  아무것도 안 쓴다.  화면에도 아무것도 안 그린다.
--
-- 왜 재나
-- -------
-- CD-DA 스케줄러를 **뱅크1 에 상주시키지 않고** 렌더러처럼 AC 에 두었다가
-- 재생 중에만 빌린 RAM 으로 복사해 쓰려고 한다.  그러면 뱅크 비용이
-- 467 B -> 약 35 B 로 준다 (2026-09-04 계산).
--
--     $5B80-$5E3F   704 B   지금 배포 경로가 쓰는 범위 (스크립트 VM 데이터 스택)
--     $5B80-$5FFF  1152 B   lifecycle POC 가 AC $1C0000 저장/복원으로 빌렸던 범위
--     렌더러                 615 B  ->  $5B80-$5DE6
--     ★ 남는 꼬리            $5DE7-$5FFF = 537 B   <- 여기에 스케줄러를 놓고 싶다
--
-- 그런데 이 꼬리에는 $5E40 (게임의 선적재 루틴 NORMAL_PRELOADER) 이 있다.
-- lifecycle POC 는 통째로 저장/복원해서 피했지만, 배포 경로는 저장/복원을
-- 안 한다 -- 그냥 덮는다.  그러니 **CD-DA 재생 중에 이 꼬리가 정말 죽어
-- 있는지**를 먼저 봐야 한다.  살아 있으면 그 자리에 스케줄러를 놓는 순간
-- 게임이 죽는다.
--
-- ⚠ 이 프로브는 "안 건드린다" 를 증명하려는 것이다.  그러므로 **한 장면만
--   보고 끝내면 안 된다.**  오프닝(트랙 17) 은 물론이고 대사 장면·메뉴·
--   장면 전환까지 돌려 보고 그래도 0 이어야 의미가 있다.
--
-- 무엇을 세나
-- -----------
--   1  $5DE7-$5FFF 의 읽기 · 쓰기 · 실행    (누가 어디서 건드렸는지 PC 와 함께)
--   2  같은 것을 STATE($7FDF)==2 인 프레임만 따로  (= 자막 엔진이 떠 있을 때)
--   3  AC 포트의 base 래치를 디코드해 **AC 어느 페이지를 건드리는지** 지도
--      -> $1FEB00 (mini index 를 선적재하려는 자리) 가 정말 아무도 안 쓰는지
--
-- 산출물  C:/snatcher/dump/borrow_tail_0_5_165_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/borrow_tail_0_5_165_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tkind\taddr\tpc\tstate\n')

local function say(m) emu.log(m); print(m) end

-- 보고 싶은 꼬리.  렌더러 615 B 뒤부터 빌린 범위 끝까지.
local TAIL_LO, TAIL_HI = 0x5DE7, 0x5FFF
local STATE_AT = 0x7FDF

local frame = 0
local hit   = { read = 0, write = 0, exec = 0 }
local hit2  = { read = 0, write = 0, exec = 0 }   -- STATE==2 인 동안만
local seen  = {}          -- "kind/pc" -> 횟수.  같은 곳은 한 번만 로그한다
local rows  = 0

local PCKEY = nil
local function pc_of()
  local ok, s = pcall(emu.getState)
  if not ok or not s then return -1 end
  if PCKEY == nil then
    PCKEY = false
    for _, k in ipairs({ 'cpu.pc', 'pc' }) do
      if type(s[k]) == 'number' then PCKEY = k break end
    end
    if not PCKEY then
      local names = {}
      for k, v in pairs(s) do if type(v) == 'number' then names[#names+1] = k end end
      table.sort(names)
      say('  ⚠ PC 키를 못 찾았다.  전체 키: ' .. table.concat(names, ' '))
    end
  end
  return PCKEY and s[PCKEY] or -1
end

local function watch(kind)
  return function(addr)
    hit[kind] = hit[kind] + 1
    local st = emu.read(STATE_AT, MEM, false) or -1
    if st == 2 then hit2[kind] = hit2[kind] + 1 end
    local pc  = pc_of()
    local key = ('%s/%04X/%04X'):format(kind, addr or 0, pc)
    seen[key] = (seen[key] or 0) + 1
    if seen[key] == 1 and rows < 400 then
      rows = rows + 1
      say(('★접촉  f%-7d %-5s $%04X  PC $%04X  STATE %d')
            :format(frame, kind, addr or 0, pc, st))
      out:write(('%d\t%s\t%04X\t%04X\t%d\n'):format(frame, kind, addr or 0, pc, st))
      out:flush()
    end
  end
end

emu.addMemoryCallback(watch('read'),  emu.callbackType.read,  TAIL_LO, TAIL_HI, CPU, MEM)
emu.addMemoryCallback(watch('write'), emu.callbackType.write, TAIL_LO, TAIL_HI, CPU, MEM)
emu.addMemoryCallback(watch('exec'),  emu.callbackType.exec,  TAIL_LO, TAIL_HI, CPU, MEM)

-- ---- AC 페이지 지도 -------------------------------------------------------
-- AC 포트는 base 를 $1A?2/3/4 에 쓴 뒤 $1A?0/1 로 흐른다.  base 래치를 잡아
-- "어느 AC 페이지를 열었나" 를 센다.  게임은 Arcade Card 를 안 쓰므로 여기
-- 나오는 것은 전부 우리 코드다 -- 그래서 우리 할당표 검산이 된다.
local acbase = { [0] = { 0, 0, 0 }, [1] = { 0, 0, 0 } }
local acpage = {}

local function latch(port, which)
  return function(addr, value)
    acbase[port][which] = value or 0
    if which == 3 then
      local a = acbase[port][1] | (acbase[port][2] << 8) | (acbase[port][3] << 16)
      local page = a & 0xFFFF00
      acpage[page] = (acpage[page] or 0) + 1
    end
  end
end

for port = 0, 1 do
  local p = 0x1A00 + port * 0x10
  for which = 1, 3 do
    emu.addMemoryCallback(latch(port, which), emu.callbackType.write,
                          p + 1 + which, p + 1 + which, CPU, MEM)
  end
end

-- ---- 심박 ----------------------------------------------------------------
emu.addEventCallback(function()
  frame = frame + 1
  if frame % 600 == 0 then
    say(('  심박 f%-7d  꼬리 read %d · write %d · exec %d   '
         .. '(STATE==2 중  %d / %d / %d)')
          :format(frame, hit.read, hit.write, hit.exec,
                  hit2.read, hit2.write, hit2.exec))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:write(('# 꼬리 $%04X-$%04X  read %d · write %d · exec %d\n')
              :format(TAIL_LO, TAIL_HI, hit.read, hit.write, hit.exec))
  out:write(('# STATE==2 중        read %d · write %d · exec %d\n')
              :format(hit2.read, hit2.write, hit2.exec))
  local pages = {}
  for page in pairs(acpage) do pages[#pages+1] = page end
  table.sort(pages)
  out:write('# AC 페이지 접근\n')
  for _, page in ipairs(pages) do
    out:write(('# AC $%06X  x%d\n'):format(page, acpage[page]))
  end
  out:close()

  say('')
  say(('끝 -- 꼬리 $%04X-$%04X'):format(TAIL_LO, TAIL_HI))
  say(('   read %d · write %d · exec %d'):format(hit.read, hit.write, hit.exec))
  say(('   STATE==2 중  read %d · write %d · exec %d')
        :format(hit2.read, hit2.write, hit2.exec))
  if hit.read + hit.write + hit.exec == 0 then
    say('   ★ 한 번도 안 건드렸다 -- 다른 장면에서도 0 이면 스케줄러를 놓아도 된다')
  else
    say('   ★ 살아 있다 -- 저장/복원 없이는 이 자리를 못 쓴다.  위 PC 를 볼 것')
  end
  say('   AC 페이지:')
  for _, page in ipairs(pages) do
    local mark = (page == 0x1FEB00) and '   <- ★ mini index 를 놓으려던 자리' or ''
    say(('     $%06X  x%d%s'):format(page, acpage[page], mark))
  end
  if acpage[0x1FEB00] == nil then
    say('     ★ $1FEB00 은 아무도 안 열었다 -- mini index 선적재 가능')
  end
  say('   ' .. PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.165-borrow-tail-alive armed -- 순수 관측 (0.4.7.1 에 올릴 것)')
say(('  꼬리 $%04X-$%04X 의 read/write/exec 를 센다.  0 이어야 한다'):format(TAIL_LO, TAIL_HI))
say('  ⚠ 오프닝만 보지 말 것.  대사·메뉴·장면전환까지 돌려야 의미가 있다')
say('  ' .. PATH)
