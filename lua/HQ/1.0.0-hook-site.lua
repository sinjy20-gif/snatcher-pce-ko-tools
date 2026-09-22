-- ★ HQ 1.0.0 -- 장소 전환 훅 자리 찾기 (트랙 3 한정) (2026-09-06 밤)
--
-- 무엇을 찾나
-- ----------
-- 소유자 설계 (인계서 §38):
--
--     트랙 시작 = 자막 시간축 시작
--     ★장소 변경 = 출력 안전자리 변경   <- 게임의 전환 코드에 훅을 건다
--     트랙 종료 = 자막 종료
--
-- CD-DA 엔진이 "언제 장소가 바뀌는가" 를 추측할 필요가 없어진다.  게임이 장소를
-- 바꾸는 행위 자체가 트리거다.  그러려면 **그 전환 코드가 어디인지** 알아야 한다.
--
-- 후보는 이미 실측으로 있다 (0.7.0, 0.5.17 실기):
--
--     frame 10132 · 트랙 3 의 35.4 초 · 접수처 -> 국장실 전환 순간
--     게임이 $5B85~$5B88 (우리가 빌린 슬롯) 에 썼다
--         pc = 9C27 / 9C46 / 9C63 / 9C80
--
-- 그런데 $9Cxx 는 **MPR4($8000-$9FFF)** 구역이고, MPR4 는 장면마다 바뀐다
-- (0.3.1 실측: $86 · $7C · $75 ...).  그래서 주소만으로는 역어셈블할 수 없다.
--
-- 이 판이 하는 일
-- --------------
-- 트랙 3 재생 중에 **게임이 슬롯에 쓰는 순간**을 잡아서
--
--     1  MPR0~7 을 통째로 남긴다      -> 어느 뱅크인지 확정
--     2  그 pc 주변 **코드 바이트 192 B** 를 CPU 공간에서 떠 온다
--        (그 순간의 매핑이 곧 옳은 뱅크다 -- 뱅크를 몰라도 코드가 손에 들어온다)
--
-- 그러면 에뮬 없이 정적으로 역어셈블해서 이것을 가릴 수 있다:
--
--     □ 이게 장소 전환 루틴인가, 그냥 VM 스택 조작인가
--     □ 장소마다 따로인가, 하나를 공유하는가   (훅 1 개 vs N 개)
--     □ 훅을 박을 바이트가 있는가
--
-- ★ 트랙 3 한정이다 ($26F9 & $7F == 3).  다른 트랙은 안 본다.
--
-- 읽기 전용.  화면에 아무것도 안 그린다.
--
-- 쓰는 법
--     Power Cycle -> 이 파일 하나만 -> 트랙 3 을 자동 진행으로 국장실까지
--     (0.5.10 은 트랙 3 자막이 없어 슬롯을 안 빌리므로 **자막이 있는 판**으로
--      돌려야 잡힌다.  _archive/scrapped_20260906/0.5.18 을 쓸 것)
--
-- 산출  dump/hq_1_0_0_hook_site_<시각>.tsv        사건 + 코드 바이트

local VERSION = '1.0.0'
local MEM = emu.memType.pceMemory

local SLOT_LO, SLOT_HI = 0x5B80, 0x5E1E
local CD_RAW  = 0x26F9
local STATE_AT = 0x7FDF

local DUMP_BACK, DUMP_FWD = 64, 128     -- pc 앞뒤로 뜰 바이트

local stamp = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/hq_' .. VERSION:gsub('%.', '_')
            .. '_hook_site_' .. stamp .. '.tsv'
local out = assert(io.open(OUT, 'w'))
out:write('frame\tpc\taddr\tval\tstate\tmpr\tfrom\tbytes\n')

local function rb(at) return emu.read(at, MEM) or 0 end

local function mprHex(s)
  local t = {}
  for i = 0, 7 do
    t[#t + 1] = string.format('%02X', s['memoryManager.mpr[' .. i .. ']'] or 0)
  end
  return table.concat(t, ' ')
end

local frame, rows = 0, 0
local seen = {}          -- pc -> 이미 떴다

emu.addMemoryCallback(function(address, value)
  -- ★ 트랙 3 재생 중만
  if (rb(CD_RAW) & 0x7F) ~= 3 then return end
  local s = emu.getState() or {}
  local pc = s['cpu.pc'] or 0
  -- 우리 코드(슬롯·상주부·스케줄러·BIOS)는 관심 없다.  게임만.
  if pc >= SLOT_LO and pc <= SLOT_HI then return end
  if pc >= 0x7F00 then return end
  if pc >= 0xEC00 then return end
  if seen[pc] then return end
  seen[pc] = true

  local from = pc - DUMP_BACK
  if from < 0 then from = 0 end
  local bytes = {}
  for i = 0, DUMP_BACK + DUMP_FWD - 1 do
    bytes[#bytes + 1] = string.format('%02X', rb(from + i))
  end
  out:write(string.format('%d\t%04X\t%04X\t%02X\t%02X\t%s\t%04X\t%s\n',
    frame, pc, address, value or 0, rb(STATE_AT), mprHex(s), from,
    table.concat(bytes)))
  out:flush(); rows = rows + 1
  emu.log(string.format('★ 훅후보 pc=%04X  슬롯 $%04X<-%02X  frame=%d',
    pc, address, value or 0, frame))
end, emu.callbackType.write, SLOT_LO, SLOT_HI, emu.cpuType.pce, MEM)

emu.addEventCallback(function() frame = frame + 1 end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:write(string.format('# rows=%d frames=%d\n', rows, frame))
  out:close()
  emu.log(string.format('★ 후보 %d 개 -> %s', rows, OUT))
end, emu.eventType.scriptEnded)

emu.log('HQ ' .. VERSION .. ' -- 장소 전환 훅 자리 찾기 (트랙 3 한정) · 읽기 전용')
emu.log('  트랙 3 중 게임이 슬롯 $5B80-$5E1E 에 쓰는 pc 를 잡아')
emu.log('  MPR 과 주변 코드 192 B 를 같이 뜬다')
emu.log('  ⚠ 자막이 있는 판으로 돌릴 것 (_archive/scrapped_20260906/0.5.18)')
emu.log('  -> ' .. OUT)
