-- SUB 0.5.161 -- 게임이 줄 148~250 사이에 AC 를 건드리는가
--
-- ★ 순수 관측.  아무것도 안 고친다.  게임 무수정.
--
-- 왜 재나
-- ---------------------------------------------------------------------------
-- 국장실 소환 고침은 무거운 arm 작업을 **줄 148 뒤로** 옮기는 것이다.
-- 갈고리는 BIOS 의 RCR 설정 루틴 `$E424`(STA $0000) -- 프레임당 3 번 불리고
-- 그중 2 번째가 줄 160 이다.
--
--     ⚠ 그런데 `$E424` 는 **게임의 래스터 IRQ 핸들러 한복판**이다.
--       지금까지 우리 arm 은 FEC4(상주부 문맥)에서만 돌았다.
--       IRQ 안에서 AC 를 건드린 적이 한 번도 없다.
--
-- armer 스스로도 이렇게 적어놨다:
--     "게임이 쓰던 AC channel1 문맥($1A12-$1A19)을 보존한다"
-- 즉 **게임도 AC 를 쓴다.**  우리가 그 시각에 AC 포인터를 옮기면 깨질 수 있다.
--
-- 무엇을 재나
-- ---------------------------------------------------------------------------
--     $1A00~$1A1F 접근(읽기·쓰기) 전부 · 스캔라인 · PC
--     PC 로 주인을 가른다:
--         뱅크1 $F0EA~$FC76   우리 디스패처/armer
--         $5B80~$5E1F         우리 엔진/헬퍼
--         $7F00~$7FFF         상주부 (우리가 훅한 게임 코드)
--         그 외               ★ 게임
--
-- 판정
--     줄 148~250 에 **게임** 접근이 0      -> 그 창은 비어 있다.  설계 그대로 진행
--     0 이 아니다                          -> 채널 문맥을 저장/복원해야 한다
--                                             (또는 카운터를 AC 밖에 둬야 한다)
--
-- ★ 상한 없음.  게임 접근은 전부 남긴다 (인계서 §2-1 규칙)
--
-- 산출물  C:/snatcher/dump/ac_in_irq_0_5_161_<시각>.tsv

local AC_LO, AC_HI = 0x1A00, 0x1A1F
local WIN_LO, WIN_HI = 148, 250        -- 우리가 노리는 창

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/ac_in_irq_0_5_161_' .. STAMP .. '.tsv'
local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local out = io.open(PATH, 'w')
out:write('kind\tpc\towner\tline\taddr\n')
local function say(m) emu.log(m); print(m) end

local LINE_KEY
local function scanline()
  local ok, s = pcall(emu.getState)
  if not ok or not s then return -1 end
  if LINE_KEY == nil then
    LINE_KEY = false
    for _, k in ipairs({'vdc.scanline', 'scanline', 'vdc.vCounter', 'ppu.scanline'}) do
      if type(s[k]) == 'number' then LINE_KEY = k break end
    end
  end
  if LINE_KEY == false then return -1 end
  local v = s[LINE_KEY]
  return type(v) == 'number' and math.floor(v) or -1
end

local PC_KEY
local function pcNow()
  local ok, s = pcall(emu.getState)
  if not ok or not s then return -1 end
  if PC_KEY == nil then
    PC_KEY = false
    for _, k in ipairs({ 'cpu.pc', 'pc' }) do
      if type(s[k]) == 'number' then PC_KEY = k break end
    end
  end
  if PC_KEY == false then return -1 end
  local v = s[PC_KEY]
  return type(v) == 'number' and math.floor(v) or -1
end

local function owner(pc)
  if pc >= 0xF0EA and pc <= 0xFC76 then return '우리-뱅크1' end
  if pc >= 0x5B80 and pc <= 0x5E1F then return '우리-엔진' end
  if pc >= 0x7F00 and pc <= 0x7FFF then return '상주부' end
  if pc >= 0xE000 then return 'BIOS' end
  return '★게임'
end

local counts, gameInWindow, gamePCs = {}, 0, {}
local total = 0

local function note(kind, address)
  local pc = pcNow()
  local ln = scanline()
  local who = owner(pc)
  total = total + 1
  local k = who
  counts[k] = (counts[k] or 0) + 1
  if who == '★게임' then
    out:write(('%s\t%04X\t%s\t%d\t%04X\n'):format(kind, pc, who, ln, address))
    if ln >= WIN_LO and ln <= WIN_HI then
      gameInWindow = gameInWindow + 1
      gamePCs[pc] = (gamePCs[pc] or 0) + 1
      if gameInWindow <= 12 then
        say(('★게임이 창 안에서 AC 접근  pc=$%04X  줄%d  $%04X  (%s)'):format(
          pc, ln, address, kind))
      end
    end
    out:flush()
  end
end

emu.addMemoryCallback(function(address) note('R', address) end,
  emu.callbackType.read, AC_LO, AC_HI, CPU, MEM)
emu.addMemoryCallback(function(address) note('W', address) end,
  emu.callbackType.write, AC_LO, AC_HI, CPU, MEM)

local frame = 0
emu.addEventCallback(function()
  frame = frame + 1
  if frame % 1800 == 0 then
    say(('== 프레임 %d · AC 접근 %d 회 =='):format(frame, total))
    for k, n in pairs(counts) do say(('   %-12s %d'):format(k, n)) end
    say(('   ★ 게임이 줄 %d~%d 에서 AC 접근: %d 회'):format(WIN_LO, WIN_HI, gameInWindow))
    for pc, n in pairs(gamePCs) do say(('      pc=$%04X x%d'):format(pc, n)) end
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function() out:close() end, emu.eventType.scriptEnded)
say('SUB 0.5.161-ac-in-irq armed -- 순수 관측')
say(('  ★ 판정: 게임이 줄 %d~%d 에서 AC 를 건드리는가'):format(WIN_LO, WIN_HI))
say('  ' .. PATH)
