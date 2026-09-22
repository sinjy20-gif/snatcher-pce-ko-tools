-- SUB 0.5.82 -- 자막 없는 판에서 임대 구간의 빈 자리를 고른다 (대조군 측정)
--
-- 왜 자막 없는 판인가
-- ---------------------------------------------------------------------------
-- 0.5.81 은 임대 창을 helper 진입($5B83, base $7900)으로 열었다.  자막이 없는
-- 판에는 helper 가 돌지 않으므로 창이 안 열리고 아무 판정도 안 나온다.
--
-- 그런데 자막 없는 판이 자리 조사에는 **더 낫다.**  우리 엔진이 같은 구간에
-- 2,112 회를 쓰고 있으면 그만큼이 가려진다.  아무것도 안 끼어든 상태에서
-- 게임이 진짜로 건드리는 word 만 남는 게 정확하다.
--
-- 그래서 창을 LBA 로 잡는다 (0.5.80 실측값)
-- ---------------------------------------------------------------------------
-- ```
-- LBA 184018   CD-DA 시작
-- LBA 186792   임대 시작 (첫 자막)   <- 여기부터
-- LBA 187428   임대 종료 (반납)      <- 여기까지  · 507 프레임
-- ```
-- 디스크 배치는 같으므로 이 LBA 는 빌드와 무관하다.
--
-- 무엇을 답하나
-- ---------------------------------------------------------------------------
--     · 그 구간에 1,216 word (19 글자 x $40) 가 연속으로 비는 자리가 어디인가
--     · $7900 (현재 하드코딩) 이 정말 못 쓰는 자리인가
--     · $2000 (안전자리 표의 주장) 이 정말 쓸 수 있는 자리인가
--
-- ★ 표는 근거가 관측 1 회뿐이고, 그 한 번이 $7900 을 "자유" 라고 했다가
--   0.5.80 에서 320 회 충돌로 뒤집혔다.  그래서 $2000 도 특별대우 없이
--   똑같이 판정받는다.
--
-- ★ 게임을 한 바이트도 안 고친다.  화면에 아무것도 안 그린다.
-- ★ 판정은 구간이 끝나는 순간 즉시 로그로 나온다.  언로드 불필요.
--
--   자막 없는 판으로 Power Cycle -> 이 파일만 로드 -> CD-DA 를 스킵 없이 끝까지
--
-- 산출물  C:/snatcher/dump/cdda_seat_clean_0_5_82_<시각>.tsv

local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/cdda_seat_clean_0_5_82_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('kind\ta\tb\tc\n')

-- 0.5.80 실측 임대 구간
local LBA_OPEN, LBA_CLOSE = 186792, 187428
local NEED = 1216                 -- 19 글자 x $40 word
local VRAM_WORDS = 0x8000

local frame = 0
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
-- VDC 포트로 VRAM 쓰기를 복원한다 (0.5.75 의 검증된 방식)
-- ===========================================================================
local selReg, mawr = 0, 0
local open_, openFrame = false, nil
local touched = {}
local nTouched, nWrite, nAll, nOurs = 0, 0, 0, 0
-- 우리 코드가 사는 곳 (문서로 확정: 슬롯 $5B80 · resident ORIGIN $7F49)
local SLOT_LO, SLOT_HI = 0x5B80, 0x5E1E
local RES_LO,  RES_HI  = 0x7F49, 0x7FDF
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
      if open_ then
        local word = mawr & 0x7FFF
        local pc = pcNow()
        -- 이 판에 우리 코드가 남아 있을 수 있다.  우리 쓰기는 자리 계산에서 뺀다.
        -- (없는 판이면 이 분기는 그냥 0 회다)
        if (pc >= SLOT_LO and pc <= SLOT_HI) or (pc >= RES_LO and pc <= RES_HI) then
          nOurs = nOurs + 1
        else
          nWrite = nWrite + 1
          if not touched[word] then touched[word] = true; nTouched = nTouched + 1 end
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
  say('0.5.82 ** VDC 포트 콜백 설치 실패 -- 판정 불가')
  rec('fatal', 'vdc callback install failed')
end

-- ===========================================================================
local function report()
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

  say('0.5.82 ======== 자리 조사 (자막 없는 판) ========')
  say('  구간 %d 프레임 · 게임이 건드린 word %d 개 · 게임쓰기 %d 회',
      frame - (openFrame or frame), nTouched, nWrite)
  say('  (우리 코드 쓰기 %d 회 -- 자리 계산에서 제외 · VRAM 전체 %d 회)', nOurs, nAll)
  rec('summary', nTouched, nWrite, nAll)

  if nAll == 0 then
    say('  ** VRAM 쓰기를 하나도 못 봤다.  포트 감시 실패 -- 판정 불가')
    return
  end
  if nWrite == 0 then
    say('  ** 구간 안 쓰기가 0 이다.  구간을 잘못 잡았을 수 있다 (LBA 확인 필요)')
  end

  say('  %d word 이상 연속으로 비는 구간 : %d 개', NEED, #big)
  for i, sp in ipairs(big) do
    if i <= 12 then
      say('     $%04X - $%04X   (%d word)', sp[1], sp[2], sp[2] - sp[1] + 1)
    end
    rec('free_span', string.format('%04X', sp[1]), string.format('%04X', sp[2]),
        sp[2] - sp[1] + 1)
  end

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

  local ok, firstOk = 0, nil
  for base = 0, VRAM_WORDS - NEED, 0x20 do
    local clean = true
    for w = base, base + NEED - 1 do
      if touched[w] then clean = false; break end
    end
    if clean then
      ok = ok + 1; firstOk = firstOk or base
      if ok <= 16 then rec('base_ok', string.format('%04X', base)) end
    end
  end
  say('  $20 정렬 기준 쓸 수 있는 base : %d 개 · 첫 자리 $%04X', ok, firstOk or 0xFFFF)
  rec('bases', ok, firstOk and string.format('%04X', firstOk) or '')

  local pcs = {}
  for pc, n in pairs(pcSeen) do pcs[#pcs + 1] = { pc, n } end
  table.sort(pcs, function(x, y) return x[2] > y[2] end)
  say('  쓰기 PC 상위')
  for i = 1, math.min(#pcs, 6) do
    say('     pc $%04X : %d 회', pcs[i][1], pcs[i][2])
    rec('pc', string.format('%04X', pcs[i][1]), pcs[i][2])
  end
end

-- ===========================================================================
emu.addEventCallback(function()
  frame = frame + 1
  local lba = sector()
  if lba < 0 then return end

  if (not open_) and lba >= LBA_OPEN and lba < LBA_CLOSE then
    open_, openFrame = true, frame
    touched, nTouched, nWrite, nOurs = {}, 0, 0, 0
    pcSeen = {}
    say('0.5.82 *** %df  조사 구간 열림 · LBA %d', frame, lba)
    rec('open', frame, lba)
  elseif open_ and lba >= LBA_CLOSE then
    open_ = false
    say('0.5.82 *** %df  조사 구간 닫힘 · LBA %d', frame, lba)
    rec('close', frame, lba)
    report()
  end

  if open_ and (frame % 120 == 0) then
    say('0.5.82 · %df  조사중 · LBA %d · 건드린 word %d', frame, lba, nTouched)
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if open_ then say('0.5.82 (구간이 안 닫힌 채 종료) -- 지금까지로 판정'); report() end
  out:close()
  say('저장 : ' .. PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.82-cdda-seat-survey-clean armed -- 순수 관측 · 게임 무수정')
say(string.format('  조사 구간 LBA %d ~ %d (0.5.80 실측 임대 구간)', LBA_OPEN, LBA_CLOSE))
say('  덤프 : ' .. PATH)
