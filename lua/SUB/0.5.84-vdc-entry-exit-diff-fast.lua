-- SUB 0.5.84 -- 엔진 진입 직전 / 반환 직후의 VDC 상태 비교 (0.5.83 의 속도 수정판)
--
-- 0.5.83 이 1 fps 였던 이유
-- ---------------------------------------------------------------------------
-- 소유자(게임/엔진)를 가리려고 **VDC 포트 쓰기마다** emu.getState() 를 불렀다.
-- 그 콜백은 한 판에 2,002,915 회 들어온다 (0.5.80 실측).  getState 는 상태
-- 테이블을 통째로 만드므로 프레임이 죽는다.
--
-- 0.5.80 이 안 느렸던 것은 **대역에 맞은 드문 경우에만** PC 를 떴기 때문이다.
--
-- 이 판이 바꾼 것 -- 판정 내용은 0.5.83 과 같다
-- ---------------------------------------------------------------------------
--   소유자를 PC 조회 대신 **실행 콜백의 플래그**로 가린다.
--     · exec 콜백 $5B80-$5E1E 는 주소를 인자로 준다 (getState 불필요)
--     · 그 범위에 들어오면 inEngine=true, RTS($60) 를 실행하려는 순간 false
--   PC 조회는 **보고할 때 딱 두 번** 뿐이다 (최초 divergence · 최초 bandhit).
--
--   ★ 범위 안 JSR/RTS 도 RTS 를 만난다.  그래서 "나갔다" 뒤에 게임의 VDC 쓰기가
--     하나도 없었으면 진입 스냅샷을 새로 뜨지 않는다.  내부 서브루틴 복귀가
--     게임 상태를 덮어쓰는 것을 막는다.
--
-- 답하는 것 (0.5.83 과 동일 · 딱 두 개)
-- ---------------------------------------------------------------------------
--   DIVERGENCE  엔진 진입 직전(게임)과 반환 직후(우리)의
--               register select · MAWR · increment 가 처음 달라지는 지점
--   BANDHIT     게임이 $7900-$7DBF 에 처음 쓰는 순간의 PC 와 명령 바이트
--               + 그 전에 게임이 MAWR 을 다시 세웠는지
--
-- 디코더는 0.5.75 / 0.5.80 의 검증된 것 그대로
--   port 0            레지스터 선택 래치
--   port 2/3 (reg 0)  MAWR 하위/상위
--   port 3   (reg 5)  CR 상위바이트 bit3-4 = VRAM 주소 증가량
--   port 3   (reg 2)  VWR 상위 -> word 하나가 실리고 MAWR 증가
--
-- ★ 게임을 한 바이트도 안 고친다.  VRAM/RAM/AC/state/키 입력에 쓰지 않는다.
-- ★ 화면에 아무것도 그리지 않는다.
--
--   BIOS  build/patch/0.4.6.48/Syscard3_galmuri_0.4.6.48.pce + 같은 폴더 [KO].cue
--   Power Cycle -> 이 파일만 로드 -> 스킵하지 말고 CD-DA 끝까지 -> ACT1 까지
--
-- 산출물  C:/snatcher/dump/cdda_vdc_diff_0_5_84_<시각>.tsv

local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/cdda_vdc_diff_0_5_84_' .. STAMP .. '.tsv'
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

-- ★ 보고할 때만 부른다.  뜨거운 경로에서 절대 부르지 않는다.
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
-- VDC 상태
-- ===========================================================================
local selReg, mawr, crHi = 0, 0, 0
local INCNAME = { [0] = '+1', [1] = '+32', [2] = '+64', [3] = '+128' }
local function incr() return INCNAME[(crHi >> 3) & 3] end
local function snap() return { sel = selReg, mawr = mawr & 0x7FFF, inc = incr() } end
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

-- ===========================================================================
-- 소유자 -- exec 콜백 플래그 (PC 조회 없음)
-- ===========================================================================
local inEngine = false
local entrySnap, entryPc, entryFrame = nil, -1, -1
local exitSnap,  exitPc,  exitFrame  = nil, -1, -1
local gameWroteSinceExit = false        -- 나간 뒤 게임이 VDC 를 건드렸나
local gameSetMawrSinceExit = false      -- 나간 뒤 게임이 MAWR 을 다시 세웠나
local pendingCompare = false

local reportedDiv, reportedBand = false, false
local divCount, bandCount, engineWrites = 0, 0, 0

emu.addMemoryCallback(function(address)
  if not inEngine then
    inEngine = true
    -- 게임이 그 사이 VDC 를 만졌을 때만 진입 스냅샷을 새로 뜬다.
    -- (범위 안 JSR/RTS 로 다시 들어온 것이면 원래 진입값을 지킨다)
    if entrySnap == nil or gameWroteSinceExit then
      entrySnap, entryPc, entryFrame = snap(), address, frame
      gameWroteSinceExit = false
      pendingCompare = false
    end
  end
  if (emu.read(address, MEM) or 0) == 0x60 then      -- RTS -> 이 명령으로 나간다
    inEngine = false
    exitSnap, exitPc, exitFrame = snap(), address, frame
    pendingCompare = true
  end
end, emu.callbackType.exec, ENG_LO, ENG_HI, CPU, MEM)

-- ===========================================================================
-- VDC 포트 -- 뜨거운 경로.  PC 조회 없음
-- ===========================================================================
local function onVdcWrite(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF

  if inEngine then
    engineWrites = engineWrites + 1
  else
    gameWroteSinceExit = true
    -- ---- 최초 DIVERGENCE : 우리가 나간 뒤 게임이 처음 VDC 를 만지는 순간
    if pendingCompare and entrySnap and exitSnap then
      pendingCompare = false
      local changed = (entrySnap.sel ~= exitSnap.sel)
                   or (entrySnap.mawr ~= exitSnap.mawr)
                   or (entrySnap.inc ~= exitSnap.inc)
      if changed then
        divCount = divCount + 1
        if not reportedDiv then
          reportedDiv = true
          local pc = pcNow()                 -- ★ 여기서만 조회
          say('0.5.84 ***** 최초 DIVERGENCE  진입 %df -> 반환 %df', entryFrame, exitFrame)
          say('        진입 직전 (게임)  %s   진입 pc $%04X', fmt(entrySnap), entryPc)
          say('        반환 직후 (우리)  %s   RTS pc $%04X', fmt(exitSnap), exitPc)
          say('        달라진 것 :  %s', diffText(entrySnap, exitSnap))
          say('        다음 게임 쓰기 pc $%04X  %s', pc, nameOp(pc))
          rec('divergence_entry', 'frame=%d %s pc=$%04X', entryFrame, fmt(entrySnap), entryPc)
          rec('divergence_exit', 'frame=%d %s rts_pc=$%04X', exitFrame, fmt(exitSnap), exitPc)
          rec('divergence_delta', '%s', diffText(entrySnap, exitSnap))
          rec('divergence_next_game', 'pc=$%04X op=%s lba=%d bytes[%04X-%04X]=%s',
              pc, nameOp(pc), sector(), pc - 8, pc + 7, bytesAround(pc))
        end
      end
    end
  end

  -- ---- 디코더 (0.5.75 원문 그대로)
  if port == 0 then
    selReg = value
  elseif port == 2 then
    if selReg == 0 then
      mawr = (mawr & 0xFF00) | value
      if not inEngine then gameSetMawrSinceExit = true end
    end
  elseif port == 3 then
    if selReg == 0 then
      mawr = (mawr & 0x00FF) | (value << 8)
      if not inEngine then gameSetMawrSinceExit = true end
    elseif selReg == 5 then
      crHi = value
      if inEngine then rec('engine_wrote_cr', 'crHi=$%02X inc=%s', value, incr()) end
    elseif selReg == 2 then
      local word = mawr & 0x7FFF
      if (not inEngine) and word >= VRAM_FIRST and word <= VRAM_LAST then
        bandCount = bandCount + 1
        if not reportedBand then
          reportedBand = true
          local pc = pcNow()                 -- ★ 여기서만 조회
          say('0.5.84 ***** 최초 BANDHIT  %df  word $%04X  pc $%04X  %s',
              frame, word, pc, nameOp(pc))
          say('        이 쓰기 전에 게임이 MAWR 을 다시 세웠나 :  %s',
              gameSetMawrSinceExit and '예 -- 우리가 남긴 값 탓이 아니다'
                                    or '아니오 -- 우리가 남긴 MAWR 로 들어갔다')
          say('        우리 RTS pc $%04X · 진입 직전 게임 상태 %s',
              exitPc, entrySnap and fmt(entrySnap) or '(미포착)')
          say('        명령 바이트 [$%04X-$%04X]  %s', pc - 8, pc + 7, bytesAround(pc))
          rec('bandhit', 'word=$%04X pc=$%04X op=%s game_set_mawr=%s lba=%d',
              word, pc, nameOp(pc), tostring(gameSetMawrSinceExit), sector())
          rec('bandhit_bytes', '[%04X-%04X]=%s', pc - 8, pc + 7, bytesAround(pc))
          rec('bandhit_entry', 'entry=%s exit=%s',
              entrySnap and fmt(entrySnap) or 'none',
              exitSnap and fmt(exitSnap) or 'none')
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
  say('0.5.84 ** VDC 포트 콜백 설치 실패 -- 이 프로브는 아무 판정도 못 한다')
  rec('fatal', 'vdc callback install failed')
end

emu.addEventCallback(function()
  frame = frame + 1
  if frame % 1800 == 0 then
    rec('heartbeat', 'divergence=%d bandhit=%d engine_writes=%d lba=%d',
        divCount, bandCount, engineWrites, sector())
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  say('0.5.84 끝 -- divergence %d 회 · bandhit %d 회 · 엔진쓰기 %d',
      divCount, bandCount, engineWrites)
  rec('end', 'divergence=%d bandhit=%d engine_writes=%d', divCount, bandCount, engineWrites)
  out:close()
  say('저장 : ' .. PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.84-vdc-entry-exit-diff-fast armed -- 순수 관측 · 게임 무수정 · 화면 무간섭')
say('  소유자는 exec 플래그로 가린다 (PC 조회는 보고할 때 두 번뿐)')
say('  판정 내용은 0.5.83 과 같다 -- DIVERGENCE 와 BANDHIT')
say('  덤프 : ' .. PATH)
