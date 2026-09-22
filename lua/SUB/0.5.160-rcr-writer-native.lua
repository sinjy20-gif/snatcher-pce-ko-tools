-- SUB 0.5.160 -- RCR 을 쓰는 PC 를 잰다  ★네이티브 빌드용
--
-- 0.5.20 에서 무엇이 바뀌었나
-- ---------------------------------------------------------------------------
--   1) `dofile('.../0.4.89-vdc-rearm.lua')` 제거
--      08-29 Lua 자막 체인을 네이티브 빌드에 겹치면 **게임이 깨진다** (실측).
--   2) `$7F4A == NOP` 오염 가드 제거
--      우리 출하 빌드는 그것을 **영구히** NOP 으로 굽는다
--      (manifest `resident_delta: 7F4A: SEI 78 -> NOP EA only`).
--      0.5.16 잔재가 아니라 정상 상태다 -- 옛 가드는 오탐이다.
--
-- 왜 재나 -- 국장실 뒷화면 소환의 고침 자리를 고른다
-- ---------------------------------------------------------------------------
-- 원인은 확정됐다: arm 1 회가 엔진 671 B 를 AC 포트로 복사하느라 뱅크1 에서
-- 4,300 명령(≈57 스캔라인)을 먹고, 줄 24 에서 시작해 **줄 32 의 래스터 IRQ 를
-- 밀어낸다.**  그 프레임만 화면 위쪽이 옛 스크롤(천장)로 그려진다.
--
-- 고칠 방향 셋 중 소유자 순위는 3 > 2 > 1 이다:
--     1  vblank 로 이동   ★ 산술적으로 죽었다.  vblank 10,900 cyc vs 복사 25,800 cyc
--     2  2~3 프레임 분할  안전하지만 위험 구간에서 복사하는 구조는 그대로
--     3  줄 148 뒤로 이동 근본적.  분할선을 다 지난 뒤 무거운 일을 한다
--
-- 3 번의 관문은 **그 시각에 도는 코드에 붙을 수 있는가** 다.
--     PC 가 BIOS($E000~$FFFF)  -> 훅 가능.  3 번 성립
--     PC 가 상주부($7Fxx)      -> 감사 불변식(resident_modified:false) 위반.  막힘
--     PC 가 스크립트 VM($6000~$7FFF) -> 장면마다 갈려 못 쓴다
--
-- ★ 오염된 판에서 이미 `$E42C` 가 나왔다 (BIOS).  이 판은 그것을 깨끗하게 확인한다.
--
-- 무엇을 재나
-- ---------------------------------------------------------------------------
--   1) RCR 쓰기의 **PC**            누가 쓰는가.  분할선마다 다른 놈인가
--   2) SEI 창의 시작/끝 스캔라인    $7F49(PHP) 진입 · $7F85(PLP) 이탈
--   3) 그 둘의 관계                 창이 닫힌 줄 vs RCR=135 를 쓴 줄
--        붙어 있으면    창이 직접 막고 있다
--        멀면           중간에 다른 대기/연쇄가 있다.  그 PC 를 파야 한다
--   4) ★ 각 PC 주변 코드를 파일로 덤프한다
--        -> 다음 왕복 없이 바로 디스어셈해서 "루틴"을 찾는다
--
-- 읽는 법 (로그 한 줄)
--     f12345 창[21..38] · 135 을 줄33 에 · writer $E1A7   <- 창 직후.  창이 범인
--     f12345 창[21..38] · 135 을 줄190 에 · writer $E1A7  <- 창과 무관.  연쇄 있음
--
-- ★ 쓰기 0 이면 판정 불가.  ★ 오염(0.5.16/17/18 잔재) 감지되면 판정 무효.
-- 읽기 전용이다 (파일 출력 외에는 게임 상태를 안 바꾼다).
--
-- Power Cycle 뒤 이 파일 하나만 로드한다.  디스크는 0.4.6.17-reviewed.
-- 국장실에서 대사를 여러 번 흘린다.

assert(rawget(_G, 'SUB_FRAGMENT_FORCE_KEY') == nil and
       rawget(_G, 'SUB_FRAGMENT_FORCE_BASE') == nil,
       '재무장 엔진에서는 SUB_FRAGMENT_FORCE_KEY/BASE 를 쓸 수 없다')

-- ★ 0.5.160: dofile 제거 -- 네이티브 빌드에 옛 Lua 체인을 겹치면 게임이 깨진다

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local WIN_IN, WIN_OUT = 0x7F49, 0x7F85     -- PHP / PLP  (상주부 디스어셈)
local NOP = 0xEA

local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT   = 'C:/snatcher/dump/rcr_writer_0_5_160_' .. STAMP .. '.tsv'
local CODE  = 'C:/snatcher/dump/rcr_writer_code_0_5_160_' .. STAMP .. '.txt'
local out   = io.open(OUT, 'w')
local code  = io.open(CODE, 'w')
if out then out:write('frame\tscreen_line\trcr\twrite_line\twriter_pc\twin_in\twin_out\n') end

-- ---------------------------------------------------------------------------
-- 상태 읽기.  키 이름은 Mesen 판마다 다르므로 한 번만 찾아 캐시한다.
-- ---------------------------------------------------------------------------
local LINE_KEY, PC_KEY

local function stateOf()
  local ok, s = pcall(emu.getState)
  if not ok or type(s) ~= 'table' then return nil end
  if LINE_KEY == nil then
    LINE_KEY = false
    for _, k in ipairs({ 'vdc.scanline', 'scanline', 'vdc.vCounter' }) do
      if type(s[k]) == 'number' then LINE_KEY = k; break end
    end
  end
  if PC_KEY == nil then
    PC_KEY = false
    for _, k in ipairs({ 'cpu.pc', 'pc' }) do
      if type(s[k]) == 'number' then PC_KEY = k; break end
    end
  end
  return s
end

local function scanline()
  local s = stateOf()
  if not s or LINE_KEY == false then return -1 end
  local v = s[LINE_KEY]
  return type(v) == 'number' and math.floor(v) or -1
end

-- ★ Mesen 은 PC 를 "명령 시작 + 2" 로 보고한다 (BIOS 로 교정함, §8).
--   STA abs 는 3 바이트이므로 보정하면 명령의 시작이 나온다.
local PC_BIAS = 2
local function writerPC()
  local s = stateOf()
  if not s or PC_KEY == false then return -1 end
  local v = s[PC_KEY]
  if type(v) ~= 'number' then return -1 end
  return (math.floor(v) - PC_BIAS) & 0xFFFF
end

-- ---------------------------------------------------------------------------
-- 교차 오염 가드 -- Mesen 은 스크립트를 다시 로드해도 RAM 을 초기화하지 않는다
-- ---------------------------------------------------------------------------
local FOREIGN = {
  -- ★ 0.5.160: $7F4A NOP 가드 제거 -- 우리 출하 빌드는 이것을 **영구히** NOP 으로 굽는다
  --   (resident_delta: '7F4A: SEI 78 -> NOP EA only').  0.5.16 잔재가 아니므로 오탐이다
  { at = 0x7F5B, bad = NOP,  name = '0.5.17/18 helper copy offload' },
  { at = 0x7F6F, bad = NOP,  name = '0.5.17/18 renderer copy offload' },
}
local dirty = false
local function checkForeign()
  if dirty then return end
  for _, f in ipairs(FOREIGN) do
    if (emu.read(f.at, MEM) or -1) == f.bad then
      dirty = true
      emu.log(string.format('SUB 0.5.160 ★★ 오염 감지 -- $%04X 가 NOP (%s 잔재)', f.at, f.name))
      emu.log('   Power Cycle 하고 이 파일만 다시 로드할 것.  지금 판정은 무효다')
      return
    end
  end
end

-- ---------------------------------------------------------------------------
-- ★ writer PC 주변 코드 덤프.  다음 왕복 없이 디스어셈하기 위한 것이다.
--   호출 시점의 뱅크 매핑 그대로 읽으므로 "실제로 실행된 코드"가 나온다.
-- ---------------------------------------------------------------------------
local dumped = {}
local function dumpAround(pc)
  if pc < 0 or dumped[pc] or not code then return end
  dumped[pc] = true
  local lo = math.max(0, pc - 0x40)
  local hi = math.min(0xFFFF, pc + 0x80)
  local hex = {}
  for a = lo, hi do hex[#hex + 1] = string.format('%02X', emu.read(a, MEM) or 0) end

  -- MPR 도 같이 남긴다 (이 PC 가 어느 물리 뱅크였는지 되짚기 위해)
  local s = stateOf()
  local mpr = {}
  if s then
    for i = 0, 7 do
      local v = s['cpu.mpr[' .. i .. ']'] or s['mpr' .. i] or s['memoryManager.mpr[' .. i .. ']']
      mpr[#mpr + 1] = type(v) == 'number' and string.format('%02X', v) or '??'
    end
  end

  code:write(string.format('\n== writer PC $%04X ==  MPR %s\n', pc, table.concat(mpr, ' ')))
  code:write(string.format('org $%04X\n', lo))
  for i = 1, #hex, 32 do
    code:write(string.format('%04X  %s\n', lo + i - 1,
               table.concat(hex, ' ', i, math.min(i + 31, #hex))))
  end
  code:flush()
  emu.log(string.format('SUB 0.5.160 ★ CODE DUMP writer $%04X (%d B)', pc, hi - lo + 1))
end

-- ---------------------------------------------------------------------------
-- 측정
-- ---------------------------------------------------------------------------
local selReg, rcr = 0, 0
local frame = 0
local lo_writes, hi_writes = 0, 0
local perFrame = {}
local winIn, winOut = -1, -1
local seen, reported = {}, 0

emu.addMemoryCallback(function(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF
  if port == 0 then selReg = value; return end
  if selReg ~= 0x06 then return end
  if port == 2 then
    rcr = (rcr & 0xFF00) | value
    lo_writes = lo_writes + 1
  elseif port == 3 then
    rcr = (rcr & 0x00FF) | (value << 8)
    hi_writes = hi_writes + 1
    local pc = writerPC()
    dumpAround(pc)
    perFrame[#perFrame + 1] = {
      line = scanline(), rcr = rcr & 0x03FF, screen = (rcr & 0x03FF) - 64, pc = pc,
    }
  end
end, emu.callbackType.write, 0x0000, 0x0003, CPU, MEM)

emu.addMemoryCallback(function() winIn  = scanline() end,
  emu.callbackType.exec, WIN_IN, WIN_IN, CPU, MEM)
emu.addMemoryCallback(function() winOut = scanline() end,
  emu.callbackType.exec, WIN_OUT, WIN_OUT, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  checkForeign()

  local list, wi, wo = perFrame, winIn, winOut
  perFrame, winIn, winOut = {}, -1, -1

  if #list > 0 then
    local parts = {}
    for _, w in ipairs(list) do
      parts[#parts + 1] = string.format('%d@줄%d<-$%04X', w.screen, w.line, w.pc)
    end
    -- 창의 폭은 프레임마다 다르므로 서명에서 뺀다.  같은 (분할선, writer) 조합만 센다
    local sigParts = {}
    for _, w in ipairs(list) do
      sigParts[#sigParts + 1] = string.format('%d<-$%04X', w.screen, w.pc)
    end
    local sig = table.concat(sigParts, ' ')
    seen[sig] = (seen[sig] or 0) + 1

    if seen[sig] <= 3 or (wo >= 0 and wi >= 0 and (wo - wi) > 60) then
      reported = reported + 1
      emu.log(string.format('SUB 0.5.160 %df · 창[%d..%d] %s · %s',
        frame, wi, wo,
        (wi >= 0 and wo >= 0) and string.format('(%d줄)', wo - wi) or '(창 없음)',
        table.concat(parts, ' ')))
    end

    if out then
      for _, w in ipairs(list) do
        out:write(string.format('%d\t%d\t%d\t%d\t%04X\t%d\t%d\n',
                  frame, w.screen, w.rcr, w.line, w.pc, wi, wo))
      end
      out:flush()
    end
  end

  emu.drawString(4, 84, string.format(
    '0.5.160 RCR lo/hi %d/%d · writer %d종 · 보고 %d%s',
    lo_writes, hi_writes, (function() local n = 0; for _ in pairs(dumped) do n = n + 1 end; return n end)(),
    reported, dirty and ' · ★오염 판정무효' or ''),
    dirty and 0x4040FF or (hi_writes > 0 and 0x80FF80 or 0x4040FF), 0x000000)
end, emu.eventType.endFrame)

emu.log('SUB 0.5.160-rcr-writer-pc armed -- RCR 을 쓰는 PC 와 SEI 창의 관계를 잰다')
emu.log('  형식: 창[진입줄..이탈줄] (폭) · 화면줄@예약줄<-writerPC')
emu.log('  ★ lo/hi 쓰기 수가 다르면 저바이트만 쓰는 경로가 있다는 뜻 -- 알려줄 것')
emu.log('  ★ 쓰기 0 이면 판정 불가')
emu.log('  로그: ' .. OUT)
emu.log('  코드: ' .. CODE)
