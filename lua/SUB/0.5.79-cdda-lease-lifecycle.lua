-- SUB 0.5.79 -- CD-DA 임대 생명주기 (0.5.78 의 계측 결함을 고친 판)
--
-- 0.5.78 이 무엇을 못 했나
-- ---------------------------------------------------------------------------
-- 파종 성공은 확실히 쟀다.  그런데 **정작 판정에 필요한 숫자를 못 냈다.**
--
--     1  요약을 scriptEnded 에만 뒀다.  언로드 안 하면 통째로 안 나온다
--     2  덤프 경로가 상대경로였다.  Mesen 작업디렉터리가 달라 조용히 실패한다
--        (성공 사례 CDDA_NATIVE_TRACE 는 절대경로 + 로드 시점 open + 흘려쓰기)
--     3  helper 진입을 모아만 두고 요약에서 찍었다.  그래서 "임대 창 닫힘" 이
--        안 나온 이유를 알 수 없다
--
-- 0.5.78 이 실제로 남긴 것 (0.4.6.51)
-- ---------------------------------------------------------------------------
-- ```
-- 4567f  시계 켜짐
-- 6780f  임대 창 열림 (helper cmd=0 base=$7900)
-- 6781f  renderer elapsed=2189 hi=$08 · 문턱표 8C 83 7B  -> 파종 성공
-- 7287f  STATE=3
-- ```
-- ★ 6780f 에 helper 가 base $7900 으로 **열렸는데**, 닫히는 진입이 안 잡혔다.
--   STATE 는 3 이 됐는데 복원 helper 를 못 봤다.  셋 중 하나다.
--     (a) helper 는 돌았는데 그때 base 가 $7900 이 아니었다
--     (b) $5B83 에서 안 돌았다 (복원이 다른 경로다)
--     (c) 그 순간 슬롯이 helper 가 아니어서 서명 검사에 걸러졌다
--   그래서 이 판은 $5B83 진입을 **조건 없이 전부** 찍는다.
--
-- 이 판이 답할 것
-- ---------------------------------------------------------------------------
--     ★1  임대 창 동안 게임이 $7900 대역에 쓰는가   -> ACT1 파손의 범인
--     ★2  임대 시점의 LBA(sector)                  -> 안전자리 표 조회가 되는가
--          (표의 c17_001 창은 186750~187368 이다)
--      3  $5B83 진입 전부 (cmd/base/서명)          -> 닫힘이 왜 안 잡혔나
--      4  시계 자리 $1F2720 을 우리 말고 누가 쓰는가
--
-- ★ 게임을 한 바이트도 안 고친다.  화면에 아무것도 안 그린다.
-- ★ 숫자는 전부 **즉시** 로그로 나온다.  언로드에 의존하지 않는다.
--
-- 돌리는 법
--     Power Cycle -> 이 파일 하나만 로드
--     BIOS  build/patch/0.4.6.51/Syscard3_galmuri_0.4.6.51.pce
--     CUE   같은 폴더 [KO].cue
--     스킵하지 말고 CD-DA 를 끝까지 재생 -> ACT1 까지
--
-- 산출물  C:/snatcher/dump/cdda_lease_0_5_79_<시각>.tsv

local MEM  = emu.memType.pceMemory
local VRAM = emu.memType.pceVideoRam
local AC   = emu.memType.pceArcadeCardRam
local CPU  = emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/cdda_lease_0_5_79_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tevent\tdetail\n')

local CLOCK = 0x1F2720
local MAGIC_LO, MAGIC_HI = 0x5A, 0xA5

local SLOT         = 0x5B80
local HELPER_ENTRY = 0x5B83
local HELPER_SIG   = { 0xAD, 0x30, 0x5D, 0xD0 }
local CTL_CMD      = 0x5D30
local CTL_LO, CTL_HI = 0x5D34, 0x5D35

local R_TIMER   = SLOT + 602        -- $5DDA  첫 opcode SEC($38)
local R_ELAPSED = SLOT + 669        -- $5E1D lo / $5E1E hi
local R_THRESH  = SLOT + 666

local STATE     = 0x7FDF
local CDDA_BASE = 0x7900
local SPAN      = 19 * 128          -- 2,432 B
local FIRST_TH  = 2188

local frame = 0

local function rd(a, t) return emu.read(a, t or MEM) or -1 end

local function say(fmt, ...)
  local s = string.format(fmt, ...)
  emu.log(s)
end

local function rec(ev, fmt, ...)
  local d = select('#', ...) > 0 and string.format(fmt, ...) or (fmt or '')
  out:write(string.format('%d\t%s\t%s\n', frame, ev, d))
  out:flush()
end

-- CD 자신의 위치.  CDDA_NATIVE_TRACE 0.1.0 과 같은 방식.
local sectorKey = nil
local function sector()
  local ok, s = pcall(emu.getState)
  if not ok or not s then return -1 end
  if sectorKey == nil then
    for _, k in ipairs({ 'cdrom.audioPlayer.currentSector',
                         'cdrom.audio.currentSector',
                         'cdrom.currentSector' }) do
      if s[k] ~= nil then sectorKey = k; break end
    end
  end
  local v = sectorKey and s[sectorKey] or nil
  return type(v) == 'number' and math.floor(v) or -1
end

local function clockOn()
  local lo, hi = rd(CLOCK, AC), rd(CLOCK + 1, AC)
  local el = ((rd(CLOCK + 3, AC) & 0xFF) << 8) | (rd(CLOCK + 2, AC) & 0xFF)
  return (lo == MAGIC_LO and hi == MAGIC_HI), el
end

-- ===========================================================================
-- ★1  $7900 대역 VRAM 쓰기.  임대 중이 아니어도 항상 센다.
--     전체가 0 이면 "게임이 안 쓴다" 가 아니라 "콜백이 안 잡혔다" 일 수 있다.
--     그 둘을 구분할 수 없으면 판정하지 않는다.
-- ===========================================================================
local leaseOpen, leaseOpenFrame = false, nil
local writesInLease, writesTotal = 0, 0
local samplePCs = {}

emu.addMemoryCallback(function(addr)
  writesTotal = writesTotal + 1
  if not leaseOpen then return end
  writesInLease = writesInLease + 1
  if #samplePCs < 12 then
    local ok, s = pcall(emu.getState)
    local pc = (ok and s and (s['cpu.pc'] or (s.cpu and s.cpu.pc))) or -1
    samplePCs[#samplePCs + 1] = string.format('%df $%04X pc$%04X', frame, addr, pc)
    rec('vram_write', '$%04X pc$%04X', addr, pc)
  end
end, emu.callbackType.write, CDDA_BASE * 2, CDDA_BASE * 2 + SPAN - 1, CPU, VRAM)

-- ===========================================================================
-- 파종 확인.  $5DDA 에서 실행 중이면 그 8 KB 페이지가 확실히 renderer 다.
-- endFrame 에서 $5E1D 를 읽으면 다른 뱅크를 볼 수 있다 (예전 $7F4A 오작동).
-- ===========================================================================
local seedSeen = nil
emu.addMemoryCallback(function()
  if seedSeen ~= nil then return end
  local re = ((rd(R_ELAPSED + 1) & 0xFF) << 8) | (rd(R_ELAPSED) & 0xFF)
  seedSeen = re
  local t1, t2, t3 = rd(R_THRESH), rd(R_THRESH + 1), rd(R_THRESH + 2)
  say('0.5.79 *** %df  renderer timer 최초 진입 elapsed=%d hi=$%02X  문턱 %02X %02X %02X',
      frame, re, (re >> 8) & 0xFF, t1, t2, t3)
  rec('seed', 'elapsed=%d thresh=%02X%02X%02X', re, t1, t2, t3)
  if t1 ~= 0x8C or t2 ~= 0x83 or t3 ~= 0x7B then
    say('           ** 문턱표가 다르다 -- CD-DA renderer 가 아니다.  판정 보류')
  elseif math.abs(re - FIRST_TH) <= 4 then
    say('           ==> 파종 성공')
  else
    say('           ==> 파종 실패.  %d 프레임 밀린다', FIRST_TH - re)
  end
end, emu.callbackType.exec, R_TIMER, R_TIMER, CPU, MEM)

-- ===========================================================================
-- 3.  $5B83 진입을 **조건 없이 전부** 찍는다.
--     0.5.78 은 서명이 안 맞으면 조용히 건너뛰어서, 닫힘이 왜 안 잡혔는지
--     알 수 없었다.  이 판은 서명까지 같이 남긴다.
-- ===========================================================================
local entries = 0
emu.addMemoryCallback(function()
  entries = entries + 1
  local isHelper = true
  for i = 1, #HELPER_SIG do
    if rd(HELPER_ENTRY + i - 1) ~= HELPER_SIG[i] then isHelper = false end
  end
  local cmd  = rd(CTL_CMD)
  local base = ((rd(CTL_HI) & 0xFF) << 8) | (rd(CTL_LO) & 0xFF)
  local sig  = string.format('%02X %02X %02X %02X', rd(HELPER_ENTRY),
                 rd(HELPER_ENTRY + 1), rd(HELPER_ENTRY + 2), rd(HELPER_ENTRY + 3))

  rec('slot_entry', 'helper=%s cmd=%d base=$%04X sig=%s',
      tostring(isHelper), cmd, base, sig)
  if entries <= 40 then
    say('0.5.79 · %df  $5B83 진입 #%d  helper=%s cmd=%d base=$%04X  sig=%s',
        frame, entries, tostring(isHelper), cmd, base, sig)
  end

  if not isHelper then return end

  if base == CDDA_BASE and cmd == 0 and not leaseOpen then
    leaseOpen, leaseOpenFrame = true, frame
    writesInLease = 0
    local lba = sector()
    say('0.5.79 *** %df  임대 창 열림 · base $%04X · LBA %d', frame, base, lba)
    say('           표의 c17_001 창은 186750~187368 -- 안에 드는가: %s',
        (lba >= 186750 and lba <= 187368) and '예' or '아니오')
    rec('lease_open', 'base=$%04X lba=%d', base, lba)
  elseif base == CDDA_BASE and cmd ~= 0 and leaseOpen then
    leaseOpen = false
    local lba = sector()
    say('0.5.79 *** %df  임대 창 닫힘 · 길이 %d 프레임 · LBA %d',
        frame, frame - (leaseOpenFrame or frame), lba)
    say('           ★ 이 창 동안 $%04X 대역 쓰기 = %d 회 (전체 누적 %d)',
        CDDA_BASE, writesInLease, writesTotal)
    if writesTotal == 0 then
      say('           ** 전체가 0 이다.  VRAM 쓰기 콜백이 안 잡혔을 수 있다.  판정 불가')
    elseif writesInLease > 0 then
      say('           ==> $7900 은 임대 구간에 비어있지 않다.  복원이 게임 그림을 덮는다')
    else
      say('           ==> 임대 구간엔 아무도 안 썼다.  ACT1 파손의 범인은 다른 데 있다')
    end
    rec('lease_close', 'len=%d lba=%d writes_in=%d writes_total=%d',
        frame - (leaseOpenFrame or frame), lba, writesInLease, writesTotal)
  end
end, emu.callbackType.exec, HELPER_ENTRY, HELPER_ENTRY, CPU, MEM)

-- ===========================================================================
-- 매 프레임: 시계 · STATE · 임대 중 진행상황을 **즉시** 찍는다
-- ===========================================================================
local prevRaw = { -1, -1, -1, -1 }
local prevState = -1
local foreign = 0

emu.addEventCallback(function()
  frame = frame + 1

  local raw = { rd(CLOCK, AC), rd(CLOCK + 1, AC), rd(CLOCK + 2, AC), rd(CLOCK + 3, AC) }
  if prevRaw[1] ~= -1 then
    local wasOn = (prevRaw[1] == MAGIC_LO and prevRaw[2] == MAGIC_HI)
    local isOn  = (raw[1] == MAGIC_LO and raw[2] == MAGIC_HI)
    if (not wasOn) and isOn then
      say('0.5.79 *** %df  시계 켜짐 · LBA %d', frame, sector())
      rec('clock_on', 'lba=%d', sector())
    elseif wasOn and (not isOn) then
      say('0.5.79 · %df  매직 파괴 · elapsed=%d',
          frame, (prevRaw[4] << 8) | prevRaw[3])
      rec('clock_off', 'elapsed=%d', (prevRaw[4] << 8) | prevRaw[3])
    elseif (not wasOn) and (not isOn) then
      local ch = false
      for i = 1, 4 do if raw[i] ~= prevRaw[i] then ch = true end end
      if ch then
        foreign = foreign + 1
        if foreign <= 3 then
          say('0.5.79 ** %df  시계 자리를 우리가 아닌 것이 건드린다 (%d 회째)',
              frame, foreign)
          rec('foreign_clock', '%02X%02X%02X%02X -> %02X%02X%02X%02X',
              prevRaw[1], prevRaw[2], prevRaw[3], prevRaw[4],
              raw[1], raw[2], raw[3], raw[4])
        end
      end
    end
  end
  prevRaw = raw

  local st = rd(STATE)
  if st ~= prevState then
    say('0.5.79 · %df  state $%02X -> $%02X  (임대중 쓰기 %d / 전체 %d)',
        frame, prevState < 0 and 0xFF or prevState, st, writesInLease, writesTotal)
    rec('state', '%02X->%02X writes_in=%d writes_total=%d',
        prevState, st, writesInLease, writesTotal)
    prevState = st
  end

  -- 임대 중에는 60 프레임마다 진행상황을 즉시 남긴다 (언로드에 의존 금지)
  if leaseOpen and (frame % 60 == 0) then
    say('0.5.79 · %df  임대중 %d 프레임째 · $7900 쓰기 %d 회',
        frame, frame - (leaseOpenFrame or frame), writesInLease)
    rec('lease_tick', 'elapsed_in=%d writes_in=%d',
        frame - (leaseOpenFrame or frame), writesInLease)
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  say('0.5.79 끝 -- $5B83 진입 %d 회 · $7900 쓰기 임대중 %d / 전체 %d · 시계 외부간섭 %d',
      entries, writesInLease, writesTotal, foreign)
  rec('end', 'entries=%d writes_in=%d writes_total=%d foreign=%d',
      entries, writesInLease, writesTotal, foreign)
  out:close()
  say('저장 : ' .. PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.79-cdda-lease-lifecycle armed -- 순수 관측 · 게임 무수정')
say('  숫자는 즉시 로그로 나온다.  언로드 안 해도 된다')
say('  덤프 : ' .. PATH)
