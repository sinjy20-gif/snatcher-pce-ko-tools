-- SUB 0.5.83 -- 엔진 진입 직전 / 반환 직후의 VDC 상태를 비교한다
--
-- 이 판이 답하는 것 (딱 두 개)
-- ---------------------------------------------------------------------------
--   DIVERGENCE  엔진이 들어가기 직전의 VDC 상태와 나온 직후의 상태가
--               처음으로 달라지는 지점.  register select · MAWR · increment
--   BANDHIT     그 뒤 게임이 처음으로 $7900-$7DBF 에 쓰는 순간의
--               정확한 PC 와 그 자리의 명령 바이트
--
-- 왜 계측이 먼저인가
-- ---------------------------------------------------------------------------
-- HuC6270 은 선택된 레지스터도 MAWR 도 **되읽을 수 없다** (NOTES.md 미결 항목).
-- 그래서 "진입 직전 값" 을 아는 주체가 지금은 Lua 밖에 없다.  그 값을 모른 채
-- 복원 코드를 쓰면 그건 복원이 아니라 새 가설이다.  이 판이 그 값을 준다.
--
-- 디코더는 0.5.75 / 0.5.80 의 검증된 것을 그대로 쓴다
-- ---------------------------------------------------------------------------
--   port 0            레지스터 선택 래치
--   port 2/3 (reg 0)  MAWR 하위/상위
--   port 2/3 (reg 5)  CR -- 상위바이트 bit3-4 가 VRAM 주소 증가량
--   port 3   (reg 2)  VWR 상위 -> 이때 word 하나가 실리고 MAWR 이 증가한다
--
--   PC $5B80~$5E1E    우리 엔진 (helper 슬롯 + renderer 슬롯)
--   그 밖             게임
--
-- 실측 기준선 (0.5.80 · 0.5.82)
-- ---------------------------------------------------------------------------
--   자막 OFF   임대 구간 $7900 충돌 0        · 게임 writer 는 $650C 가 최다
--   자막 ON    7122f  $7D00-$7D0B 를 pc $650C 가 씀 · 엔진은 직전까지 1024 word
--
-- ★ 게임을 한 바이트도 안 고친다.  VRAM/RAM/AC/state/키 입력에 쓰지 않는다.
-- ★ 화면에 아무것도 그리지 않는다.
-- ★ 판정은 그 순간 즉시 로그와 TSV 로 나온다.  언로드에 의존하지 않는다.
--
--   BIOS  build/patch/0.4.6.48/Syscard3_galmuri_0.4.6.48.pce  + 같은 폴더 [KO].cue
--   Power Cycle -> 이 파일만 로드 -> 스킵하지 말고 CD-DA 를 끝까지 -> ACT1 까지
--
-- 산출물  C:/snatcher/dump/cdda_vdc_diff_0_5_83_<시각>.tsv

local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/cdda_vdc_diff_0_5_83_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tevent\tdetail\n')

local ENG_LO, ENG_HI = 0x5B80, 0x5E1E        -- 우리 엔진이 사는 구간
local CDDA_BASE  = 0x7900
local VRAM_FIRST = CDDA_BASE
local VRAM_LAST  = CDDA_BASE + 1216 - 1      -- $7DBF

local frame = 0
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

-- 명령 바이트를 그 자리에서 뜬다.  블록전송이면 PC 가 명령 주소로 찍히므로
-- 앞뒤를 같이 떠서 어느 쪽이 명령 머리인지 눈으로 가른다.
local function bytesAround(pc)
  if pc < 0 then return '----' end
  local t = {}
  for a = pc - 8, pc + 7 do
    if a >= 0 and a <= 0xFFFF then
      t[#t + 1] = string.format('%02X', emu.read(a, MEM) or 0)
    else
      t[#t + 1] = '--'
    end
  end
  return table.concat(t, ' ')
end

local BLOCK = { [0x73] = 'TII', [0xC3] = 'TDD', [0xD3] = 'TIN',
                [0xE3] = 'TIA', [0xF3] = 'TAI' }
local function nameOp(pc)
  if pc < 0 then return '?' end
  local op = emu.read(pc, MEM) or 0
  if BLOCK[op] then
    local dst = (emu.read(pc + 3, MEM) or 0) | ((emu.read(pc + 4, MEM) or 0) << 8)
    return string.format('%s dst=$%04X', BLOCK[op], dst)
  end
  if op == 0x8D then return 'STA abs' end
  if op == 0x9D then return 'STA abs,X' end
  if op == 0x03 then return 'ST0' end
  if op == 0x13 then return 'ST1' end
  if op == 0x23 then return 'ST2' end
  return string.format('op $%02X', op)
end

-- ===========================================================================
-- VDC 상태 (0.5.75 / 0.5.80 의 검증된 디코더)
-- ===========================================================================
local selReg, mawr, crHi = 0, 0, 0
local INCNAME = { [0] = '+1', [1] = '+32', [2] = '+64', [3] = '+128' }
local function incr() return INCNAME[(crHi >> 3) & 3] end

local function snap()
  return { sel = selReg, mawr = mawr & 0x7FFF, inc = incr() }
end
local function fmt(s)
  return string.format('sel=$%02X mawr=$%04X inc=%s', s.sel, s.mawr, s.inc)
end
local function diffText(a, b)
  local t = {}
  if a.sel ~= b.sel then
    t[#t + 1] = string.format('select $%02X->$%02X', a.sel, b.sel)
  end
  if a.mawr ~= b.mawr then
    t[#t + 1] = string.format('MAWR $%04X->$%04X (%+d word)',
                              a.mawr, b.mawr, b.mawr - a.mawr)
  end
  if a.inc ~= b.inc then
    t[#t + 1] = string.format('increment %s->%s', a.inc, b.inc)
  end
  return #t > 0 and table.concat(t, ' · ') or '(같음)'
end

-- 소유자 전이 추적
local prevOwner = 'game'            -- 'game' | 'engine'
local entrySnap, entryPc, entryFrame = nil, -1, -1
local lastEnginePc = -1
local gameSetMawrSinceExit = false

-- 보고는 각 한 번만 (최초 divergence 한 개 · 최초 band hit 한 개)
local reportedDiv, reportedBand = false, false
local divCount, bandCount = 0, 0

local function onVdcWrite(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF
  local pc = pcNow()
  local owner = (pc >= ENG_LO and pc <= ENG_HI) and 'engine' or 'game'

  -- ---- 전이: 게임 -> 엔진.  이 쓰기를 적용하기 **전** 이 게임의 상태다
  if owner == 'engine' and prevOwner == 'game' then
    entrySnap, entryPc, entryFrame = snap(), pc, frame
    gameSetMawrSinceExit = false
  end

  -- ---- 전이: 엔진 -> 게임.  이 쓰기를 적용하기 **전** 이 우리가 남긴 상태다
  if owner == 'game' and prevOwner == 'engine' then
    local exitSnap = snap()
    gameSetMawrSinceExit = false
    if entrySnap then
      local changed = (entrySnap.sel ~= exitSnap.sel)
                   or (entrySnap.mawr ~= exitSnap.mawr)
                   or (entrySnap.inc ~= exitSnap.inc)
      if changed then
        divCount = divCount + 1
        if not reportedDiv then
          reportedDiv = true
          say('0.5.83 ***** 최초 DIVERGENCE  %df -> %df', entryFrame, frame)
          say('        진입 직전 (게임)  %s   pc $%04X', fmt(entrySnap), entryPc)
          say('        반환 직후 (우리)  %s   엔진 마지막 pc $%04X',
              fmt(exitSnap), lastEnginePc)
          say('        달라진 것 :  %s', diffText(entrySnap, exitSnap))
          say('        다음 게임 쓰기 pc $%04X  %s', pc, nameOp(pc))
          rec('divergence_entry', 'frame=%d %s pc=$%04X', entryFrame,
              fmt(entrySnap), entryPc)
          rec('divergence_exit', '%s engine_last_pc=$%04X', fmt(exitSnap),
              lastEnginePc)
          rec('divergence_delta', '%s', diffText(entrySnap, exitSnap))
          rec('divergence_next_game', 'pc=$%04X op=%s lba=%d bytes[%04X-%04X]=%s',
              pc, nameOp(pc), sector(), pc - 8, pc + 7, bytesAround(pc))
        end
      end
    end
  end

  prevOwner = owner
  if owner == 'engine' then lastEnginePc = pc end

  -- ---- 디코더 (0.5.75 원문 그대로)
  if port == 0 then
    selReg = value
  elseif port == 2 then
    if selReg == 0 then
      mawr = (mawr & 0xFF00) | value
      if owner == 'game' then gameSetMawrSinceExit = true end
    end
  elseif port == 3 then
    if selReg == 0 then
      mawr = (mawr & 0x00FF) | (value << 8)
      if owner == 'game' then gameSetMawrSinceExit = true end
    elseif selReg == 5 then
      crHi = value
      if owner == 'engine' then
        rec('engine_wrote_cr', 'pc=$%04X crHi=$%02X inc=%s', pc, value, incr())
      end
    elseif selReg == 2 then
      local word = mawr & 0x7FFF
      if owner == 'game' and word >= VRAM_FIRST and word <= VRAM_LAST then
        bandCount = bandCount + 1
        if not reportedBand then
          reportedBand = true
          say('0.5.83 ***** 최초 BANDHIT  %df  word $%04X  pc $%04X  %s',
              frame, word, pc, nameOp(pc))
          say('        이 쓰기 전에 게임이 MAWR 을 다시 세웠나 :  %s',
              gameSetMawrSinceExit and '예 -- 우리가 남긴 값 탓이 아니다'
                                    or '아니오 -- 우리가 남긴 MAWR 로 들어갔다')
          say('        엔진 마지막 pc $%04X · 진입 직전 게임 상태 %s',
              lastEnginePc, entrySnap and fmt(entrySnap) or '(미포착)')
          say('        명령 바이트 [$%04X-$%04X]  %s', pc - 8, pc + 7,
              bytesAround(pc))
          rec('bandhit', 'word=$%04X pc=$%04X op=%s game_set_mawr=%s lba=%d',
              word, pc, nameOp(pc), tostring(gameSetMawrSinceExit), sector())
          rec('bandhit_bytes', '[%04X-%04X]=%s', pc - 8, pc + 7, bytesAround(pc))
          rec('bandhit_entry', '%s', entrySnap and fmt(entrySnap) or 'none')
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
  say('0.5.83 ** VDC 포트 콜백 설치 실패 -- 이 프로브는 아무 판정도 못 한다')
  rec('fatal', 'vdc callback install failed')
end

emu.addEventCallback(function()
  frame = frame + 1
  if frame % 1800 == 0 then
    rec('heartbeat', 'divergence=%d bandhit=%d lba=%d', divCount, bandCount,
        sector())
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  say('0.5.83 끝 -- divergence %d 회 · bandhit %d 회', divCount, bandCount)
  rec('end', 'divergence=%d bandhit=%d', divCount, bandCount)
  out:close()
  say('저장 : ' .. PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.83-vdc-entry-exit-diff armed -- 순수 관측 · 게임 무수정 · 화면 무간섭')
say('  엔진 진입 직전 / 반환 직후의 select · MAWR · increment 를 비교한다')
say('  디코더는 0.5.75 / 0.5.80 의 검증된 것 그대로')
say('  덤프 : ' .. PATH)
