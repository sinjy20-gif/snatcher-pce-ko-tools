-- ★ HQ 2.0.0 -- 게임의 쓰기가 우리 **실행 코드**를 실제로 망가뜨리는가
--
-- 왜 이 판인가
-- ------------
-- §39 의 결론은 아직 **추론**이다:
--
--     "게임이 장면 전환하며 $5B81~$5B84 · $5B88.. 에 쓴다.
--      그 자리에서 우리 렌더러가 실행되고 있으므로 망가진다."
--
-- 쓰는 것은 봤지만, **그래서 우리 코드가 실제로 달라졌는지는 안 봤다.**
-- 이 판이 그것을 재고, 동시에 **게임이 쓰는 범위 전체**를 잡는다.
--
-- 앞선 실험들이 왜 다 무해했는지 (0.5.10 위에서)
--     1.1.0 슬롯 점유 · 1.2.0 VRAM 쓰기 · 1.3.0 저장/복원 · 1.4.0 스프라이트
--     -> 넷 다 "자원을 뺏기" 만 했고 **그 위에서 코드를 돌리지는 않았다.**
--
-- 이 판이 하는 일
-- --------------
--   ① 무장이 끝난 직후($7FDF 가 02 가 된 프레임) 슬롯 671 B 를 **기준 사본**으로 뜬다
--        = 그 시점의 "우리 코드 원본"
--   ② 그 뒤 10 프레임마다 슬롯을 다시 떠서 기준과 대조한다
--        달라진 바이트가 나오면 주소·기대값·실제값을 남긴다
--   ③ 무장 중(STATE=02) **게임이 슬롯에 쓴 주소를 전부** 기록한다
--        (0.8.0 은 한 줄에 몇 개만 담겨 끝을 알 수 없었다.  여기서는 전수)
--
-- 판정
--   대조에서 달라진 바이트가 나온다      -> ★§39 확정.  코드가 실제로 망가진다
--   안 나온다                            -> §39 도 죽는다.  남은 것은 VDC/AC 포트 경합
--
-- 그리고 ③ 이 **해법을 가른다**:
--   게임이 쓰는 범위가 앞쪽 수십 바이트뿐  -> 렌더러 배치를 뒤로 밀어 피한다 (쌈)
--   671 B 전역                              -> 자리로는 못 피한다.  훅 설계(§38)로
--
-- 쓰는 법
--     ★ build/patch/0.5.11 (트랙 3 자막 23줄 · 이사 없음) 으로 Power Cycle
--     이 파일 하나만 -> 트랙 3 을 자동 진행으로 국장실까지
--
-- 산출  dump/hq_2_0_0_slotdamage_<시각>.tsv

local VERSION = '2.0.0'
local MEM = emu.memType.pceMemory

local SLOT_LO, SLOT_HI = 0x5B80, 0x5E1E
local SLOT_LEN = SLOT_HI - SLOT_LO + 1        -- 671
local STATE_AT = 0x7FDF
local CD_RAW   = 0x26F9
local CHECK_EVERY = 10                        -- 프레임.  671 B 대조 주기

local stamp = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/hq_' .. VERSION:gsub('%.', '_')
            .. '_slotdamage_' .. stamp .. '.tsv'
local out = assert(io.open(OUT, 'w'))
out:write('frame\telapsed\tevent\tstate\tcd_raw\tdetail\n')

local function rb(at) return emu.read(at, MEM) or 0 end

local frame, rows = 0, 0
local ref = nil            -- 무장 직후의 기준 사본
local refFrame = nil
local armFrame = nil       -- 트랙 3 무장 프레임
local writeMap = {}        -- 주소 -> 게임이 쓴 횟수 (STATE=02 인 동안만)
local writePc  = {}        -- 주소 -> 마지막으로 쓴 pc
local reported = {}        -- 주소 -> 이미 "달라졌다" 고 보고했다

local function el()
  return armFrame and string.format('%.2f', (frame - armFrame) / 60) or '-'
end

local function line(ev, detail)
  out:write(string.format('%d\t%s\t%s\t%02X\t%02X\t%s\n',
    frame, el(), ev, rb(STATE_AT), rb(CD_RAW), detail or ''))
  out:flush(); rows = rows + 1
end

local function snapshot()
  local t = {}
  for i = 0, SLOT_LEN - 1 do t[i] = rb(SLOT_LO + i) end
  return t
end

local function compare()
  if ref == nil then return end
  local diffs, first = 0, nil
  local parts = {}
  for i = 0, SLOT_LEN - 1 do
    local now = rb(SLOT_LO + i)
    if now ~= ref[i] then
      diffs = diffs + 1
      if first == nil then first = i end
      if not reported[i] and #parts < 12 then
        parts[#parts + 1] = string.format('%04X:%02X->%02X',
          SLOT_LO + i, ref[i], now)
        reported[i] = true
      end
    end
  end
  if diffs > 0 and #parts > 0 then
    line('DAMAGE', string.format('달라진 %d B · 처음 $%04X · %s',
      diffs, SLOT_LO + (first or 0), table.concat(parts, ' ')))
    emu.log(string.format('★ 코드 손상 %d B · 처음 $%04X · %s초',
      diffs, SLOT_LO + (first or 0), el()))
  end
end

-- ③ 무장 중 게임이 슬롯에 쓴 주소를 전부 기록
emu.addMemoryCallback(function(address, value)
  if rb(STATE_AT) ~= 0x02 then return end
  local s = emu.getState() or {}
  local pc = s['cpu.pc'] or 0
  if pc >= SLOT_LO and pc <= SLOT_HI then return end     -- 우리 코드 자신
  if pc >= 0x7F00 then return end                        -- 상주부/BIOS
  if pc >= 0xEC00 then return end                        -- 스케줄러
  writeMap[address] = (writeMap[address] or 0) + 1
  writePc[address] = pc
end, emu.callbackType.write, SLOT_LO, SLOT_HI, emu.cpuType.pce, MEM)

-- ① 무장 완료(STATE=02) 시점에 기준 사본
emu.addMemoryCallback(function(address, value)
  if value == 0x02 and ref == nil and (rb(CD_RAW) & 0x7F) == 3 then
    -- 이 프레임 끝에 뜬다 (상주부 복사가 끝난 뒤여야 한다)
    refFrame = -1
  end
  line('STATE=' .. string.format('%02X', value or 0), '')
end, emu.callbackType.write, STATE_AT, STATE_AT, emu.cpuType.pce, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  local t = rb(CD_RAW) & 0x7F
  if t == 3 and armFrame == nil then armFrame = frame; line('TRACK3_START', '') end

  if refFrame == -1 then                       -- 무장한 그 프레임의 끝
    ref = snapshot(); refFrame = frame
    line('REF', string.format('기준 사본 %d B', SLOT_LEN))
    emu.log(string.format('★ 기준 사본 확보 frame=%d', frame))
  elseif ref ~= nil and frame % CHECK_EVERY == 0 then
    compare()
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  -- ③ 결과: 게임이 쓴 주소 범위
  local addrs = {}
  for a, _ in pairs(writeMap) do addrs[#addrs + 1] = a end
  table.sort(addrs)
  out:write('# ---- 무장 중 게임이 슬롯에 쓴 주소 ----\n')
  if #addrs == 0 then
    out:write('# (없음)\n')
  else
    out:write(string.format('# 주소 %d 개 · 범위 $%04X ~ $%04X\n',
      #addrs, addrs[1], addrs[#addrs]))
    for _, a in ipairs(addrs) do
      out:write(string.format('#   $%04X  %d회  마지막 pc=%04X\n',
        a, writeMap[a], writePc[a]))
    end
    emu.log(string.format('★ 게임이 쓴 슬롯 주소 %d 개 · $%04X~$%04X',
      #addrs, addrs[1], addrs[#addrs]))
  end
  out:write(string.format('# rows=%d frames=%d\n', rows, frame))
  out:close()
end, emu.eventType.scriptEnded)

emu.log('HQ ' .. VERSION .. ' -- 슬롯 코드 손상 + 게임 쓰기 범위 전수')
emu.log('  ⚠ build/patch/0.5.11 (트랙 3 자막 켜진 판) 으로 돌릴 것')
emu.log('  무장 직후를 기준으로 10 프레임마다 671 B 대조한다')
emu.log('  -> ' .. OUT)
