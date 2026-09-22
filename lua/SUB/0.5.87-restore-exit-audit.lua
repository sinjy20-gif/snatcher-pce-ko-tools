-- SUB 0.5.87 -- 0.4.6.57 이 실제로 두 가지를 다 했는지 본다 (관측 전용)
--
-- 0.4.6.57 이 바꾼 것 (헬퍼 restore 경로)
-- ---------------------------------------------------------------------------
-- ```
-- (1) CD-DA 는 복원 때 VRAM 에 되쓰지 않는다   -> 낡은 내용으로 덮지 않는다
-- (2) 반환 직전 MAWR 을 $1000 으로 되돌린다    -> 누수가 우리 대역으로 안 간다
-- ```
--
-- 지금까지 매번 하나씩만 고쳤다.
-- ```
--            복원 내용     복원 끝 MAWR    결과
-- .48        낡은 것 덮음  $7DC0           깨짐
-- 0.5.77     최신 갱신     $7DC0           정상   (누수가 대역 뒤라 안 보였다)
-- .52        낡은 것 덮음  $1000           깨짐
-- .56        안 덮음       $7900 ★         깨짐   (누수가 대역 앞으로 떨어졌다)
-- .57        안 덮음       $1000           ?
-- ```
--
-- 이 판이 답하는 것 -- 셋
-- ---------------------------------------------------------------------------
--   RESTORE_WRITE  복원 중 우리가 $7900-$7DBF 에 쓴 word 수.   ★ 0 이어야 한다
--   EXIT_STATE     헬퍼 반환 직전(finish 의 RTS)의 sel/MAWR.  ★ $02 / $1000
--   LEAK           반환 뒤 게임이 $7900-$7DBF 에 쓴 word 수.  ★ 0 이어야 한다
--                  0 이 아니면 첫 PC 를 찍는다
--
-- 셋 다 기대대로인데 화면이 깨지면, 원인은 이 대역 밖에 있다는 뜻이다.
--
-- 디코더는 0.5.75 / 0.5.80 의 검증된 것 그대로.  소유자는 exec 플래그로 가린다
-- (PC 조회는 보고할 때만 -- 0.5.83 이 1 fps 였던 이유가 그것이었다).
--
-- ★ 게임을 한 바이트도 안 고친다.  화면에 아무것도 안 그린다.
-- ★ 판정은 그 순간 즉시 나온다.  언로드 불필요.
--
--   BIOS  build/patch/0.4.6.57/Syscard3_galmuri_0.4.6.57.pce + 같은 폴더 [KO].cue
--   Power Cycle -> 이 파일만 로드 -> 스킵하지 말고 CD-DA -> 챕터1 까지
--
-- 산출물  C:/snatcher/dump/restore_exit_0_5_87_<시각>.tsv

local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/restore_exit_0_5_87_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tevent\tdetail\n')

-- 0.4.6.57 헬퍼 주소 (산출물 json 그대로)
local A_ENTRY, A_RESTORE, A_RTS = 0x5B83, 0x5BE8, 0x5C4A
local ENG_LO, ENG_HI = 0x5B80, 0x5E1E
local CTL_LO, CTL_HI = 0x5D34, 0x5D35

local BAND_LO, BAND_HI = 0x7900, 0x7900 + 1216 - 1     -- $7900-$7DBF

local frame = 0
local function rd(a) return emu.read(a, MEM) or -1 end
local function say(f, ...) emu.log(string.format(f, ...)) end
local function rec(ev, f, ...)
  local d = select('#', ...) > 0 and string.format(f, ...) or (f or '')
  out:write(string.format('%d\t%s\t%s\n', frame, ev, d)); out:flush()
end
local function pcNow()                                  -- 보고할 때만
  local ok, s = pcall(emu.getState)
  if not ok or not s then return -1 end
  local v = s['cpu.pc'] or (s.cpu and s.cpu.pc)
  return type(v) == 'number' and math.floor(v) or -1
end

local function isHelper()
  return rd(A_ENTRY) == 0xAD and rd(A_ENTRY + 1) == 0x30 and rd(A_ENTRY + 2) == 0x5D
end

-- ===========================================================================
-- VDC 상태 (0.5.75 검증 디코더)
-- ===========================================================================
local selReg, mawr, crHi = 0, 0, 0
local INC = { [0] = '+1', [1] = '+32', [2] = '+64', [3] = '+128' }

local inEngine = false
local restoring, restoredAt = false, nil
local nRestoreWrite, nLeak, nLease = 0, 0, 0
local leakPc, reported = nil, false

emu.addMemoryCallback(function(address)
  if not inEngine then inEngine = true end
  if (rd(address) or 0) == 0x60 then inEngine = false end
end, emu.callbackType.exec, ENG_LO, ENG_HI, CPU, MEM)

emu.addMemoryCallback(function()
  if not isHelper() then return end
  restoring = true
  nRestoreWrite = 0
  say('0.5.87 · %df  CD-DA 복원 시작 (base $%02X%02X)', frame, rd(CTL_HI), rd(CTL_LO))
  rec('restore_begin', 'base=$%02X%02X', rd(CTL_HI), rd(CTL_LO))
end, emu.callbackType.exec, A_RESTORE, A_RESTORE, CPU, MEM)

emu.addMemoryCallback(function()
  if not isHelper() or not restoring then return end
  restoring = false
  restoredAt = frame
  local ok1 = (nRestoreWrite == 0)
  local ok2 = (selReg == 0x02 and (mawr & 0x7FFF) == 0x1000)
  say('0.5.87 ***** 반환 직전 상태')
  say('        RESTORE_WRITE = %d  %s', nRestoreWrite, ok1 and 'OK (되쓰지 않았다)'
      or '★ 기대와 다름 -- 되쓰고 있다')
  say('        EXIT_STATE    = sel=$%02X mawr=$%04X inc=%s  %s',
      selReg, mawr & 0x7FFF, INC[(crHi >> 3) & 3],
      ok2 and 'OK ($1000 복원됨)' or '★ 기대와 다름')
  say('        (임대 중 우리가 대역에 쓴 word %d -- 자막을 그린 양)', nLease)
  rec('exit_state', 'restore_write=%d sel=$%02X mawr=$%04X inc=%s lease_write=%d',
      nRestoreWrite, selReg, mawr & 0x7FFF, INC[(crHi >> 3) & 3], nLease)
end, emu.callbackType.exec, A_RTS, A_RTS, CPU, MEM)

emu.addMemoryCallback(function(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF
  if port == 0 then
    selReg = value
  elseif port == 2 then
    if selReg == 0 then mawr = (mawr & 0xFF00) | value end
  elseif port == 3 then
    if selReg == 0 then
      mawr = (mawr & 0x00FF) | (value << 8)
    elseif selReg == 5 then
      crHi = value
    elseif selReg == 2 then
      local w = mawr & 0x7FFF
      if w >= BAND_LO and w <= BAND_HI then
        if inEngine then
          nLease = nLease + 1
          if restoring then nRestoreWrite = nRestoreWrite + 1 end
        elseif restoredAt then
          nLeak = nLeak + 1
          if not reported then
            reported = true
            leakPc = pcNow()
            say('0.5.87 ***** LEAK  %df  반환 뒤 게임이 $%04X 에 씀  pc $%04X',
                frame, w, leakPc)
            say('        -> MAWR 복원이 이 누수를 막지 못했다')
            rec('leak', 'word=$%04X pc=$%04X frames_after_restore=%d',
                w, leakPc, frame - restoredAt)
          end
        end
      end
      mawr = (mawr + 1) & 0xFFFF
    end
  end
end, emu.callbackType.write, 0x0000, 0x03FF, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  if restoredAt and (frame - restoredAt) == 300 then
    say('0.5.87 ===== 복원 뒤 300 프레임  LEAK = %d  %s', nLeak,
        nLeak == 0 and '★ 누수 없음' or ('첫 pc $' .. string.format('%04X', leakPc or 0)))
    rec('leak_summary', 'count=%d', nLeak)
  end
  if frame % 1800 == 0 then
    rec('tally', 'lease=%d restore_write=%d leak=%d', nLease, nRestoreWrite, nLeak)
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  rec('end', 'lease=%d leak=%d', nLease, nLeak)
  out:close(); say('저장 : ' .. PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.87-restore-exit-audit armed -- 순수 관측 · 게임 무수정 · 화면 무간섭')
say('  묻는 것 셋 : RESTORE_WRITE=0 · EXIT_STATE=$1000 · LEAK=0')
say('  덤프 : ' .. PATH)
