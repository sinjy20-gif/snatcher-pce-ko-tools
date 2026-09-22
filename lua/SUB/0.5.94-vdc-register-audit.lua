-- SUB 0.5.94 -- VDC 레지스터 20 개를 전수 감사한다 (관측 전용 · 마지막 남은 자리)
--
-- 여기까지 지워진 것들 (2026-09-01)
-- ---------------------------------------------------------------------------
-- ```
-- $7900-$7DBF   원본과 완전히 같음 (0.5.91) · 복원은 정답값을 되돌린다
-- BAT · SATB    원본과 같음.  우리 SATB 기입 68 word 는 게임이 매 프레임 덮는다 (0.5.93)
-- 팔레트        스프라이트 15 의 2 색만 우리 것 (0.5.92)
-- $6F00-$6FFF   자막 그리기 **전에** 이미 다름 = 번역 디스크의 사전 차이
-- ```
-- VRAM 도 팔레트도 아니면 남는 것은 **표시 설정**뿐이다.
--
-- 무엇을 보나
-- ---------------------------------------------------------------------------
-- VDC 레지스터 $00-$13 전부를 그림자로 추적한다.
--
-- ```
-- $00 MAWR  $01 MARR  $02 VWR/VRR  $05 CR    $06 RCR
-- $07 BXR   $08 BYR   $09 MWR      $0A HSR   $0B HDR
-- $0C VPR   $0D VDW   $0E VCR      $0F DCR   $10 SOUR
-- $11 DESR  $12 LENR  $13 DVSSR
-- ```
--
-- 우리 엔진(PC $5B80-$5E1E) 이 **어느 레지스터를 건드리는지**, 그리고 진입 직전
-- 값과 반환 직후 값이 다른 레지스터가 무엇인지 찍는다.  0.5.85 가 MAWR 하나만
-- 봤던 것을 20 개로 넓힌 것이다.
--
-- ★ 게임을 한 바이트도 안 고친다.  화면에 아무것도 안 그린다.
-- ★ 소유자는 exec 플래그로 가린다.  PC 조회는 보고할 때만 (0.5.83 의 1 fps 교훈).
-- ★ 판정은 즉시 나온다.  언로드 불필요.
--
--   BIOS  build/patch/0.4.6.48/Syscard3_galmuri_0.4.6.48.pce + 같은 폴더 [KO].cue
--   Power Cycle -> 이 파일만 로드 -> 스킵하지 말고 CD-DA -> 챕터1 까지
--
-- 산출물  C:/snatcher/dump/vdc_audit_0_5_94_<시각>.tsv

local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce

local ENG_LO, ENG_HI = 0x5B80, 0x5E1E
local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/vdc_audit_0_5_94_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tevent\tdetail\n')

local NAME = { [0]='MAWR', 'MARR', 'VWR', '?03', '?04', 'CR', 'RCR', 'BXR',
               'BYR', 'MWR', 'HSR', 'HDR', 'VPR', 'VDW', 'VCR', 'DCR',
               'SOUR', 'DESR', 'LENR', 'DVSSR' }

local frame = 0
local function rd(a) return emu.read(a, MEM) or -1 end
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

local inEngine = false
emu.addMemoryCallback(function(address)
  if not inEngine then inEngine = true end
  if (rd(address) or 0) == 0x60 then inEngine = false end
end, emu.callbackType.exec, ENG_LO, ENG_HI, CPU, MEM)

-- 레지스터 그림자
local reg = {}
for i = 0, 0x13 do reg[i] = 0 end
local selReg = 0

local touched = {}          -- 우리가 쓴 레지스터
local entry, entryValid = nil, false
local reported, divCount = {}, 0
local prevOwner = 'game'

local function snap()
  local t = {}
  for i = 0, 0x13 do t[i] = reg[i] end
  return t
end

emu.addMemoryCallback(function(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF
  local owner = inEngine and 'engine' or 'game'

  if owner == 'engine' and prevOwner == 'game' then
    entry, entryValid = snap(), true
  elseif owner == 'game' and prevOwner == 'engine' and entryValid then
    -- 반환 직후: 우리가 안 되돌린 레지스터를 찾는다
    for i = 0, 0x13 do
      if entry[i] ~= reg[i] and not reported[i] then
        reported[i] = true
        divCount = divCount + 1
        local pc = pcNow()
        say('0.5.94 ***** 안 되돌린 레지스터  $%02X %s   진입 $%04X -> 반환 $%04X',
            i, NAME[i] or '?', entry[i], reg[i])
        say('        (반환 뒤 첫 게임 VDC 접근 pc $%04X · %df)', pc, frame)
        rec('not_restored', 'reg=$%02X name=%s entry=$%04X exit=$%04X pc=$%04X',
            i, NAME[i] or '?', entry[i], reg[i], pc)
      end
    end
    entryValid = false
  end
  prevOwner = owner

  if port == 0 then
    selReg = value & 0x1F
  elseif port == 2 or port == 3 then
    local r = selReg
    if r <= 0x13 then
      if port == 2 then reg[r] = (reg[r] & 0xFF00) | value
      else reg[r] = (reg[r] & 0x00FF) | (value << 8) end
      if owner == 'engine' and not touched[r] then
        touched[r] = true
        say('0.5.94 · %df  우리 엔진이 처음 건드린 레지스터 $%02X %s',
            frame, r, NAME[r] or '?')
        rec('engine_touch', 'reg=$%02X name=%s', r, NAME[r] or '?')
      end
      -- VWR 은 쓸 때마다 MAWR 이 증가한다
      if r == 2 and port == 3 then reg[0] = (reg[0] + 1) & 0xFFFF end
    end
  end
end, emu.callbackType.write, 0x0000, 0x03FF, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  if frame % 3600 == 0 then
    local t = {}
    for i = 0, 0x13 do if touched[i] then t[#t + 1] = string.format('$%02X', i) end end
    rec('tally', 'touched=%s not_restored=%d', table.concat(t, ','), divCount)
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  local t = {}
  for i = 0, 0x13 do
    if touched[i] then t[#t + 1] = string.format('$%02X %s', i, NAME[i] or '?') end
  end
  say('0.5.94 끝 -- 우리가 건드린 레지스터 : %s', table.concat(t, ' · '))
  say('        안 되돌린 것 %d 종', divCount)
  rec('end', 'touched=%d not_restored=%d', #t, divCount)
  out:close(); say('저장 : ' .. PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.94-vdc-register-audit armed -- 순수 관측 · 게임 무수정 · 화면 무간섭')
say('  VDC $00-$13 을 그림자로 추적한다.  우리가 건드린 것 / 안 되돌린 것을 찍는다')
say('  덤프 : ' .. PATH)
