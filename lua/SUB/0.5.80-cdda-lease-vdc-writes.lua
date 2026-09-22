-- SUB 0.5.80 -- 임대 창 동안 게임이 $7900 을 쓰는가 (0.5.79 의 미결 항목)
--
-- 0.5.79 가 답한 것 / 못 답한 것
-- ---------------------------------------------------------------------------
-- ```
-- 4714f  clock_on    LBA 184018
-- 6927f  lease_open  base $7900 · LBA 186792   <- 표의 c17_001 창(186750~187368) 안
-- 6928f  seed        elapsed=2189 · 문턱 8C 83 7B   -> 파종 성공 (재확인)
-- 7434f  lease_close 길이 507 프레임 · LBA 187428
-- 28484f end         시계 외부간섭 0 회
-- ```
-- ★ 시계 자리 $1F2720 은 28,484 프레임 동안 우리 말고 아무도 안 건드렸다.
--   (한 번도 확인 안 하고 써 왔던 자리다.  이제 근거가 생겼다.)
--
-- ✗ **핵심 질문은 못 답했다.**  writes_total = 0 이 나왔는데, 그것은
--   "게임이 안 쓴다" 가 아니라 **Mesen 에 pceVideoRam write 콜백이 없다** 는 뜻이다.
--   이미 0.5.75 주석에 적혀 있던 사실이다.  찾아보지 않고 프로브를 짠 내 잘못이다.
--
-- 이 판이 하는 일
-- ---------------------------------------------------------------------------
-- 0.5.75 가 쓴 **검증된 방식**을 그대로 재사용한다.
-- VDC 포트($0000-$03FF) 쓰기를 지켜보며 MAWR 을 복원하고, 데이터 포트에 쓸 때마다
-- 그 word 주소가 우리 대역인지 본다.
--
--     port 0        레지스터 선택 래치
--     port 2/3 (reg 0)  MAWR 하위/상위
--     port 3   (reg 2)  VWR 상위 -> 이때 word 하나가 VRAM 에 실린다
--
-- 쓴 주체는 PC 로 가른다.
--
--     PC $5B80~$5E1E  우리 엔진   (자막을 그리는 중)
--     그 밖           게임        ★ 이게 0 보다 크면 $7900 은 빈 자리가 아니다
--
-- 판정
--     임대 창 안 game > 0  -> $7900 은 임대 구간에 게임이 쓰는 자리다.
--                             복원이 게임 그림을 덮는다 -> ACT1 파손 확정.
--                             고칠 곳은 백업 시점이 아니라 **자리 선택**이다
--     임대 창 안 game = 0  -> 범인은 다른 데 있다.  복원 내용 자체를 다시 본다
--     total = 0            -> 포트 감시도 실패.  판정 불가 (이 경우를 명시한다)
--
-- ★ 게임을 한 바이트도 안 고친다.  화면에 아무것도 안 그린다.
-- ★ 숫자는 즉시 로그로 나온다.  언로드에 의존하지 않는다.
--
--     BIOS  build/patch/0.4.6.51/Syscard3_galmuri_0.4.6.51.pce
--     CUE   같은 폴더 [KO].cue   · 스킵하지 말고 CD-DA 를 끝까지 -> ACT1 까지
--
-- 산출물  C:/snatcher/dump/cdda_lease_0_5_80_<시각>.tsv

local MEM = emu.memType.pceMemory
local AC  = emu.memType.pceArcadeCardRam
local CPU = emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/cdda_lease_0_5_80_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tevent\tdetail\n')

local CLOCK = 0x1F2720
local MAGIC_LO, MAGIC_HI = 0x5A, 0xA5

local HELPER_ENTRY = 0x5B83
local HELPER_SIG   = { 0xAD, 0x30, 0x5D, 0xD0 }
local CTL_CMD      = 0x5D30
local CTL_LO, CTL_HI = 0x5D34, 0x5D35

local CDDA_BASE  = 0x7900
local VRAM_FIRST = CDDA_BASE                 -- word 주소
local VRAM_LAST  = CDDA_BASE + 1216 - 1      -- 2,432 B = 1,216 word -> $7DBF

local ENG_LO, ENG_HI = 0x5B80, 0x5E1E        -- 우리 엔진이 사는 구간

local frame = 0
local function rd(a, t) return emu.read(a, t or MEM) or -1 end
local function say(f, ...) emu.log(string.format(f, ...)) end
local function rec(ev, f, ...)
  local d = select('#', ...) > 0 and string.format(f, ...) or (f or '')
  out:write(string.format('%d\t%s\t%s\n', frame, ev, d)); out:flush()
end

local function pcNow()
  local ok, s = pcall(emu.getState)
  if not ok or not s then return -1 end
  local v = s['cpu.pc'] or (s.cpu and s.cpu.pc)
  return type(v) == 'number' and math.floor(v) or -1
end

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

-- ===========================================================================
-- VDC 포트로 VRAM 쓰기를 복원한다 (0.5.75 의 검증된 방식)
-- ===========================================================================
local selReg, mawr = 0, 0
local leaseOpen, leaseOpenFrame = false, nil
local inLeaseGame, inLeaseEngine = 0, 0
local totalBand, totalAll = 0, 0
local samples = {}

local function onVdcWrite(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF
  if port == 0 then
    selReg = value
  elseif port == 2 then
    if selReg == 0 then mawr = (mawr & 0xFF00) | value end
  elseif port == 3 then
    if selReg == 0 then
      mawr = (mawr & 0x00FF) | (value << 8)
    elseif selReg == 2 then
      totalAll = totalAll + 1
      local word = mawr & 0x7FFF
      if word >= VRAM_FIRST and word <= VRAM_LAST then
        totalBand = totalBand + 1
        if leaseOpen then
          local pc = pcNow()
          if pc >= ENG_LO and pc <= ENG_HI then
            inLeaseEngine = inLeaseEngine + 1
          else
            inLeaseGame = inLeaseGame + 1
            if #samples < 12 then
              samples[#samples + 1] = string.format('%df word$%04X pc$%04X', frame, word, pc)
              rec('game_write', 'word=$%04X pc=$%04X', word, pc)
            end
          end
        end
      end
      mawr = (mawr + 1) & 0xFFFF
    end
  end
end

local installed = pcall(function()
  emu.addMemoryCallback(onVdcWrite, emu.callbackType.write, 0x0000, 0x03FF, CPU, MEM)
end)
if not installed then
  say('0.5.80 ** VDC 포트 콜백 설치 실패 -- 이 프로브는 판정할 수 없다')
  rec('fatal', 'vdc callback install failed')
end

-- ===========================================================================
-- 임대 창은 helper 실행 지점에서 연다/닫는다 (뱅킹 안전)
--   ※ 0.5.79 의 state 열은 버린다.  $7FDF 를 endFrame 에서 폴링하니 EA(NOP) 같은
--     남의 뱅크 코드가 찍혔다.  STATE 는 이 판에서 아예 안 본다.
-- ===========================================================================
emu.addMemoryCallback(function()
  local isHelper = true
  for i = 1, #HELPER_SIG do
    if rd(HELPER_ENTRY + i - 1) ~= HELPER_SIG[i] then isHelper = false end
  end
  if not isHelper then return end            -- 슬롯이 renderer 면 CTL 은 코드다

  local cmd  = rd(CTL_CMD)
  local base = ((rd(CTL_HI) & 0xFF) << 8) | (rd(CTL_LO) & 0xFF)
  if base ~= CDDA_BASE then return end

  if cmd == 0 and not leaseOpen then
    leaseOpen, leaseOpenFrame = true, frame
    inLeaseGame, inLeaseEngine = 0, 0
    local lba = sector()
    say('0.5.80 *** %df  임대 창 열림 · base $%04X · LBA %d', frame, base, lba)
    rec('lease_open', 'base=$%04X lba=%d', base, lba)
  elseif cmd ~= 0 and leaseOpen then
    leaseOpen = false
    local len = frame - (leaseOpenFrame or frame)
    say('0.5.80 *** %df  임대 창 닫힘 · 길이 %d 프레임 · LBA %d', frame, len, sector())
    say('           ★ 창 안 $%04X-$%04X 쓰기 :  게임 %d 회 · 우리엔진 %d 회',
        VRAM_FIRST, VRAM_LAST, inLeaseGame, inLeaseEngine)
    say('             (대역 누적 %d · VRAM 전체 누적 %d)', totalBand, totalAll)
    if totalAll == 0 then
      say('           ** VRAM 쓰기를 하나도 못 봤다.  포트 감시 실패 -- 판정 불가')
    elseif inLeaseGame > 0 then
      say('           ==> ★ $7900 은 임대 구간에 게임이 쓰는 자리다.')
      say('               복원이 게임 그림을 덮는다.  ACT1 파손의 원인 확정.')
      say('               고칠 곳은 백업 시점이 아니라 **자리 선택**이다')
      for i = 1, #samples do say('               %s', samples[i]) end
    else
      say('           ==> 임대 구간엔 게임이 안 썼다.  범인은 다른 데 있다')
    end
    rec('lease_close', 'len=%d game=%d engine=%d band=%d all=%d',
        len, inLeaseGame, inLeaseEngine, totalBand, totalAll)
  end
end, emu.callbackType.exec, HELPER_ENTRY, HELPER_ENTRY, CPU, MEM)

-- ===========================================================================
-- 시계 관측 (참고용) + 임대 중 진행상황을 즉시 남긴다
-- ===========================================================================
local prevOn = false
emu.addEventCallback(function()
  frame = frame + 1
  local on = (rd(CLOCK, AC) == MAGIC_LO and rd(CLOCK + 1, AC) == MAGIC_HI)
  if on ~= prevOn then
    say('0.5.80 · %df  시계 %s · LBA %d', frame, on and '켜짐' or '꺼짐', sector())
    rec(on and 'clock_on' or 'clock_off', 'lba=%d', sector())
    prevOn = on
  end
  if leaseOpen and (frame % 60 == 0) then
    say('0.5.80 · %df  임대중 %d 프레임째 · 게임쓰기 %d · 엔진쓰기 %d',
        frame, frame - (leaseOpenFrame or frame), inLeaseGame, inLeaseEngine)
    rec('lease_tick', 'in=%d game=%d engine=%d',
        frame - (leaseOpenFrame or frame), inLeaseGame, inLeaseEngine)
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  say('0.5.80 끝 -- 대역 누적 %d · VRAM 전체 누적 %d', totalBand, totalAll)
  rec('end', 'band=%d all=%d', totalBand, totalAll)
  out:close()
  say('저장 : ' .. PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.80-cdda-lease-vdc-writes armed -- 순수 관측 · 게임 무수정')
say('  VDC 포트로 VRAM 쓰기를 복원한다 (0.5.75 의 검증된 방식)')
say('  덤프 : ' .. PATH)
