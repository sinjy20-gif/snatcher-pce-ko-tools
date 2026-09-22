-- ★ HQ 3.0.0 -- **다른 방이 있는가**: 게임이 안 쓰는 CPU RAM 을 찾는다
--
-- 소유자 질문 (2026-09-06 밤):
--     "게임이 방을 되찾는 35.37초간 다른 방을 구해서 이동할 순 없고?"
--
-- 지금까지 잰 것 · 안 잰 것
-- -------------------------
--   잰 것    게임이 우리 방($5B80)에서 되찾는 것은 앞 33 B ($5B81~$5BA1) 뿐이다
--            $5BA2 이후 638 B 는 무장 중 한 번도 안 건드린다            (§40-2)
--   안 잰 것  ★**671 B 짜리 빈 CPU RAM 이 다른 데 있는가**
--
-- 이 저장소는 게임의 스크립트 VM 스택을 빌려 쓴다.  그 이유가 "다른 자리가
-- 없어서" 라고 적혀 있지만, **없다고 확인한 기록은 없다.**  빌린 RAM 꼬리
-- ($5DE7-$5E3F 89 B) 만 적혀 있고 전체 지도는 없다.
-- `tools/audit_bios_free_space.py` 는 BIOS ROM 전용이라 RAM 은 못 본다.
--
-- 이 판이 하는 일
-- --------------
--   $2000-$7FFF 를 통째로 감시해 **게임이 읽거나 쓴 바이트**를 표시한다.
--   우리 코드가 낸 접근은 뺀다 (pc 로 거른다) -- 안 그러면 우리 자리가
--   "게임이 쓴다" 로 잡힌다.
--   끝에 **한 번도 안 닿은 연속 구간**을 길이순으로 낸다.
--
-- ⚠ 읽기 전용이다.  아무것도 안 쓴다.
--
-- ⚠⚠ **"이 주행에서 안 닿았다" 는 "죽었다" 가 아니다.**
--   이 저장소는 그 함정을 다섯 번 밟았다 ($5E40-$5FFF 는 원판에서 전부 $FF 라
--   빈 칸으로 봤다가 448 B 전부 실코드였다 -- AC_BASE_SLOTMAP §15).
--   그러니 이 판의 출력은 **후보 목록**이지 결론이 아니다.  후보가 나오면
--   여러 장면에서 다시 재고, 그 다음에야 손댈 것.
--
-- 쓰는 법
--     ① build/patch/0.5.10 (자막 없는 판) 으로 Power Cycle
--        ★자막 판으로 재면 우리 접근이 섞여 지도가 좁아진다 (§34 되먹임)
--     ② 이 파일 하나만 로드
--     ③ ★여러 장면을 지난다 -- 오프닝 · 본부 · 접수처 · 국장실 · 상점 · 전투
--        많이 지날수록 후보가 줄고, 남는 후보의 신뢰도가 오른다
--     ④ 스크립트를 내리면 표가 나온다
--
-- 산출  dump/hq_3_0_0_roomhunt_<시각>.tsv
--
-- ⚠ 화면에 아무것도 안 그린다.

local VERSION = '3.0.0'
local MEM = emu.memType.pceMemory

local LO, HI = 0x2000, 0x7FFF          -- 감시 범위
local MIN_RUN = 128                    -- 이 길이 이상만 보고한다
local WANT = 671                       -- 우리가 필요한 크기

-- 우리 코드가 사는 곳.  여기서 난 접근은 "게임이 썼다" 로 안 센다
local OURS = {
  { 0x5B80, 0x5E1E, '엔진 슬롯' },
  { 0x7F49, 0x7FDF, '상주부' },
  { 0xEC00, 0xF0FF, '스케줄러 (뱅크1)' },
  { 0xFC7A, 0xFFD9, 'cpu_cache 처방' },
  { 0x5E40, 0x5FFF, '선적재 루틴' },
}

local stamp = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/hq_' .. VERSION:gsub('%.', '_')
            .. '_roomhunt_' .. stamp .. '.tsv'

local touched = {}                     -- 주소 -> true (게임이 닿았다)
local firstPc = {}                     -- 주소 -> 처음 닿은 pc
local frame, gameHits, ourHits = 0, 0, 0

local function isOurs(pc)
  for _, r in ipairs(OURS) do
    if pc >= r[1] and pc <= r[2] then return true end
  end
  return false
end

local function mark(address)
  local s = emu.getState() or {}
  local pc = s['cpu.pc'] or 0
  if isOurs(pc) then ourHits = ourHits + 1; return end
  gameHits = gameHits + 1
  if not touched[address] then
    touched[address] = true
    firstPc[address] = pc
  end
end

emu.addMemoryCallback(function(address)
  mark(address)
end, emu.callbackType.write, LO, HI, emu.cpuType.pce, MEM)

emu.addMemoryCallback(function(address)
  mark(address)
end, emu.callbackType.read, LO, HI, emu.cpuType.pce, MEM)

emu.addEventCallback(function()
  frame = frame + 1
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  local out = assert(io.open(OUT, 'w'))
  out:write('kind\tlo\thi\tbytes\tnote\n')

  local n = 0
  for a = LO, HI do if touched[a] then n = n + 1 end end
  out:write(string.format('summary\t%04X\t%04X\t%d\t프레임 %d · 게임접근 %d · 우리접근 %d · 닿은 바이트 %d/%d\n',
    LO, HI, HI - LO + 1, frame, gameHits, ourHits, n, HI - LO + 1))

  -- 한 번도 안 닿은 연속 구간
  local runs = {}
  local s = nil
  for a = LO, HI + 1 do
    local free = (a <= HI) and not touched[a]
    if free and s == nil then s = a
    elseif not free and s ~= nil then
      if a - s >= MIN_RUN then runs[#runs + 1] = { s, a - 1, a - s } end
      s = nil
    end
  end
  table.sort(runs, function(p, q) return p[3] > q[3] end)

  local big = 0
  for _, r in ipairs(runs) do
    if r[3] >= WANT then big = big + 1 end
    out:write(string.format('free\t%04X\t%04X\t%d\t%s\n', r[1], r[2], r[3],
      (r[3] >= WANT) and '★671 B 들어간다 -- 후보' or ''))
  end

  out:write(string.format('verdict\t-\t-\t%d\t%s\n', big,
    (big > 0)
      and '★후보가 있다.  다른 장면에서 다시 잴 것 -- 한 주행은 증명이 아니다'
      or  '이 주행에서는 671 B 연속 자유 구간이 없다.  다른 장면에서도 그런지 볼 것'))
  out:close()
  emu.log('HQ ' .. VERSION .. ' -> ' .. OUT)
end, emu.eventType.scriptEnded)

emu.log('HQ ' .. VERSION .. ' 방 찾기 시작 (스크립트를 내리면 표가 나온다)')
