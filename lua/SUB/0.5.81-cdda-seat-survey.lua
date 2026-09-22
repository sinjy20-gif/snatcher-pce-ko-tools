-- SUB 0.5.81 -- 임대 창 동안 **실제로 비어 있는 자리**를 직접 고른다
--
-- 왜 표를 못 믿나
-- ---------------------------------------------------------------------------
-- 안전자리 표는 `c17_001` 에 대해 `$2000` 을 가리킨다.  그런데 그 근거는
-- **관측 1 회**, 즉 `cdda_vram_map_20260830_142017.tsv` 의 단 한 행이다.
-- 그 행은 이렇게 말한다.
--
--     자유구간  $1110-$4FFF (16,112 word)  ·  $5900-$7FFF (9,984 word)
--
-- 그런데 0.5.80 이 오늘 실측한 결과는 정반대다.
--
--     임대 창 507 프레임 동안 게임이 $7900-$7DBF 에 320 회 쓴다 (PC $650C)
--
-- `$7900` 은 저 자유구간 `$5900-$7FFF` 안이다.  **표가 틀렸다.**
-- 같은 한 번의 관측에서 나온 `$2000` 도 같은 이유로 틀렸을 수 있다.
-- 그것을 믿고 자리를 옮기면 같은 실수를 반복한다.
--
-- PC 분류의 근거 (이제 확정)
-- ---------------------------------------------------------------------------
--     $5B80-$5E1E   우리 helper / renderer 슬롯
--     $7F49-$7FDF   우리 resident (문서: ORIGIN $7F49)
--     그 밖         게임
--                   ※ $6463 은 우리가 "게임의 SATB 푸시 루프" 라고 적어둔 자리다.
--                     $650C 는 같은 권역이므로 게임이 맞다.
--
-- 이 판이 하는 일
-- ---------------------------------------------------------------------------
-- 임대 창 동안 **게임이 건드린 word 를 전부 기록**하고, 창이 닫힐 때
-- 1,216 word (19 글자 x $40) 가 연속으로 비는 base 를 계산해서 찍는다.
--
--     · $7900 이 정말 못 쓰는 자리인지 (기대: 못 씀)
--     · $2000 이 정말 쓸 수 있는 자리인지 (표의 주장 -- 검증 대상)
--     · 그 외에 쓸 수 있는 base 가 몇 개나 있는지
--
-- ★ 게임을 한 바이트도 안 고친다.  화면에 아무것도 안 그린다.
-- ★ 판정은 창이 닫히는 순간 즉시 로그로 나온다.  언로드 불필요.
--
--     BIOS  build/patch/0.4.6.51/Syscard3_galmuri_0.4.6.51.pce
--     CUE   같은 폴더 [KO].cue   · 스킵하지 말고 CD-DA 끝까지 -> ACT1 까지
--
-- 산출물  C:/snatcher/dump/cdda_seat_0_5_81_<시각>.tsv

local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/cdda_seat_0_5_81_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('kind\ta\tb\tc\n')

local HELPER_ENTRY = 0x5B83
local HELPER_SIG   = { 0xAD, 0x30, 0x5D, 0xD0 }
local CTL_CMD      = 0x5D30
local CTL_LO, CTL_HI = 0x5D34, 0x5D35
local CDDA_BASE    = 0x7900

local NEED = 1216                    -- 19 글자 x $40 word
local VRAM_WORDS = 0x8000            -- 32 K word

-- 우리 코드가 사는 곳 (문서로 확정)
local SLOT_LO, SLOT_HI = 0x5B80, 0x5E1E
local RES_LO,  RES_HI  = 0x7F49, 0x7FDF

local frame = 0
local function rd(a) return emu.read(a, MEM) or -1 end
local function say(f, ...) emu.log(string.format(f, ...)) end
local function rec(k, a, b, c)
  out:write(string.format('%s\t%s\t%s\t%s\n', k, tostring(a or ''),
            tostring(b or ''), tostring(c or ''))); out:flush()
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
-- VDC 포트로 VRAM 쓰기 복원 (0.5.75 의 검증된 방식)
-- ===========================================================================
local selReg, mawr = 0, 0
local leaseOpen, leaseOpenFrame = false, nil
local touched = {}                   -- 게임이 건드린 word
local nTouched, nGame, nOurs, nAll = 0, 0, 0, 0
local pcSeen = {}

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
      nAll = nAll + 1
      if leaseOpen then
        local word = mawr & 0x7FFF
        local pc = pcNow()
        local ours = (pc >= SLOT_LO and pc <= SLOT_HI)
                  or (pc >= RES_LO  and pc <= RES_HI)
        if ours then
          nOurs = nOurs + 1
        else
          nGame = nGame + 1
          if not touched[word] then
            touched[word] = true
            nTouched = nTouched + 1
          end
          pcSeen[pc] = (pcSeen[pc] or 0) + 1
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
  say('0.5.81 ** VDC 포트 콜백 설치 실패 -- 판정 불가')
  rec('fatal', 'vdc callback install failed')
end

-- ===========================================================================
-- 자유구간 계산
-- ===========================================================================
local function report()
  -- 연속 자유구간
  local spans, s = {}, nil
  for w = 0, VRAM_WORDS - 1 do
    if touched[w] then
      if s then spans[#spans + 1] = { s, w - 1 }; s = nil end
    else
      if not s then s = w end
    end
  end
  if s then spans[#spans + 1] = { s, VRAM_WORDS - 1 } end

  local big = {}
  for _, sp in ipairs(spans) do
    if sp[2] - sp[1] + 1 >= NEED then big[#big + 1] = sp end
  end

  say('0.5.81 ======== 자리 조사 결과 ========')
  say('  게임이 건드린 word %d 개 · 게임쓰기 %d 회 · 우리쓰기 %d 회 · VRAM 전체 %d 회',
      nTouched, nGame, nOurs, nAll)
  rec('summary', nTouched, nGame, nAll)

  if nAll == 0 then
    say('  ** VRAM 쓰기를 하나도 못 봤다.  포트 감시 실패 -- 판정 불가')
    return
  end

  say('  %d word 이상 연속으로 비는 구간 : %d 개', NEED, #big)
  for i, sp in ipairs(big) do
    if i <= 12 then
      say('     $%04X - $%04X   (%d word)', sp[1], sp[2], sp[2] - sp[1] + 1)
    end
    rec('free_span', string.format('%04X', sp[1]), string.format('%04X', sp[2]),
        sp[2] - sp[1] + 1)
  end

  -- 특정 후보 판정
  local function verdict(base, label)
    local bad, firstBad = 0, nil
    for w = base, base + NEED - 1 do
      if touched[w] then bad = bad + 1; firstBad = firstBad or w end
    end
    if bad == 0 then
      say('  ==> $%04X %s : 쓸 수 있다 (충돌 0)', base, label)
    else
      say('  ==> $%04X %s : ★못 쓴다 (충돌 %d word · 첫 충돌 $%04X)',
          base, label, bad, firstBad)
    end
    rec('verdict', string.format('%04X', base), label, bad)
  end
  verdict(0x7900, '(현재 하드코딩)')
  verdict(0x2000, '(안전자리 표의 주장)')

  -- 쓸 수 있는 base 를 $20 단위로 훑는다
  local ok, firstOk = 0, nil
  for base = 0, VRAM_WORDS - NEED, 0x20 do
    local clean = true
    for w = base, base + NEED - 1 do
      if touched[w] then clean = false; break end
    end
    if clean then ok = ok + 1; firstOk = firstOk or base end
  end
  say('  $20 정렬 기준 쓸 수 있는 base : %d 개 · 첫 자리 $%04X',
      ok, firstOk or 0xFFFF)
  rec('bases', ok, firstOk and string.format('%04X', firstOk) or '')

  local pcs = {}
  for pc, n in pairs(pcSeen) do pcs[#pcs + 1] = { pc, n } end
  table.sort(pcs, function(x, y) return x[2] > y[2] end)
  say('  게임 쓰기 PC 상위')
  for i = 1, math.min(#pcs, 6) do
    say('     pc $%04X : %d 회', pcs[i][1], pcs[i][2])
    rec('game_pc', string.format('%04X', pcs[i][1]), pcs[i][2])
  end
end

-- ===========================================================================
-- 임대 창 (helper 실행 지점 = 뱅킹 안전)
-- ===========================================================================
emu.addMemoryCallback(function()
  local isHelper = true
  for i = 1, #HELPER_SIG do
    if rd(HELPER_ENTRY + i - 1) ~= HELPER_SIG[i] then isHelper = false end
  end
  if not isHelper then return end

  local cmd  = rd(CTL_CMD)
  local base = ((rd(CTL_HI) & 0xFF) << 8) | (rd(CTL_LO) & 0xFF)
  if base ~= CDDA_BASE then return end

  if cmd == 0 and not leaseOpen then
    leaseOpen, leaseOpenFrame = true, frame
    touched, nTouched, nGame, nOurs = {}, 0, 0, 0
    say('0.5.81 *** %df  임대 창 열림 · LBA %d', frame, sector())
    rec('lease_open', frame, sector())
  elseif cmd ~= 0 and leaseOpen then
    leaseOpen = false
    say('0.5.81 *** %df  임대 창 닫힘 · 길이 %d 프레임 · LBA %d',
        frame, frame - (leaseOpenFrame or frame), sector())
    rec('lease_close', frame, frame - (leaseOpenFrame or frame), sector())
    report()
  end
end, emu.callbackType.exec, HELPER_ENTRY, HELPER_ENTRY, CPU, MEM)

emu.addEventCallback(function() frame = frame + 1 end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if leaseOpen then say('0.5.81 (임대 창이 안 닫힌 채 종료) -- 지금까지로 판정'); report() end
  out:close()
  say('저장 : ' .. PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.81-cdda-seat-survey armed -- 순수 관측 · 게임 무수정')
say('  임대 창 동안 실제로 비는 자리를 직접 고른다 (표를 믿지 않는다)')
say('  덤프 : ' .. PATH)
