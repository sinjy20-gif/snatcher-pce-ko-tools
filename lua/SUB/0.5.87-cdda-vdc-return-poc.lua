-- SUB 0.5.87 -- CD-DA renderer 반환 VDC 상태 복원 POC
--
-- 해결 가설
-- ---------------------------------------------------------------------------
-- CD-DA renderer가 VDC MAWR을 바꾼 뒤 RTS하면 게임의 다음 VDC 스트림이
-- renderer의 마지막 주소에서 시작한다. 이 Lua는 renderer *진입 직전*의
-- 실제 VDC 상태를 포트 write 이력으로 기억하고, 게임 push 호출 직전에 그대로
-- 되돌린다. 따라서 $1000 같은 상수를 가정하지 않는다.
--
-- 범위
-- ---------------------------------------------------------------------------
-- 현행 Track 17 CD-DA renderer만: entry=$5B83, game push 호출은 엔진에서 탐색,
-- timer=$5DDA(SEC=$38), STATE=$7FDF. ADPCM은 timer 표식이 달라 건드리지 않는다.
-- 엔진 바이트가 다르면 아무것도 쓰지 않고 중단한다.
--
-- 쓰는 것
-- ---------------------------------------------------------------------------
-- 검증된 CD-DA renderer가 게임 push를 부르기 직전에만 VDC 포트 $0000/$0002/$0003에 4회 쓴다.
-- CPU RAM/VRAM/AC/state/입력/엔진 바이트에는 쓰지 않는다. 언로드도 불필요하다.
--
-- 시험
-- ---------------------------------------------------------------------------
-- BIOS/CUE 0.4.6.48 + 이 Lua를 먼저 로드 -> Power Cycle -> 오프닝을 스킵하지
-- 않는다. Track 17 두 줄, 종료 뒤 ACT1/챕터1/접수처 화면이 모두 정상인지 본다.
-- 로그의 `restores=N mismatch=0`이면 반환마다 entry 상태가 복원된 것이다.

local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce

local ENTRY, ENG_LO, ENG_HI, TIMER, STATE = 0x5B83, 0x5B80, 0x5E1E, 0x5DDA, 0x7FDF
local frame, active, saved, vdcDirty = 0, false, nil, false
local calls, restores, cleanReturns, mismatch, skipped = 0, 0, 0, 0, 0
local layoutChecked, disabled, pushCall = false, false, nil
local sel, mawr, crHi = 0, 0, 0
local repairing = false

local function r(at) return emu.read(at, MEM) or 0 end
local function inc() return ({[0]='+1',[1]='+32',[2]='+64',[3]='+128'})[(crHi >> 3) & 3] end
local function snapshot() return {sel=sel, mawr=mawr & 0x7FFF, inc=inc()} end
local function fmt(s) return string.format('sel=$%02X mawr=$%04X inc=%s', s.sel, s.mawr, s.inc) end

-- VDC port 이력으로 write-only 상태를 재구성한다.
emu.addMemoryCallback(function(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF
  -- renderer 호출 안에서 VDC를 한 번이라도 건드린 반환만 복원 대상이다.
  -- 따라서 매 프레임 push가 돌아도 실제 포트 복원은 첫/다음 자막처럼
  -- MAWR이 변한 조각에서만 일어난다.
  if active and not repairing then vdcDirty = true end
  if port == 0 then
    sel = value
  elseif port == 2 and sel == 0 then
    mawr = (mawr & 0xFF00) | value
  elseif port == 3 then
    if sel == 0 then
      mawr = (mawr & 0x00FF) | (value << 8)
    elseif sel == 5 then
      crHi = value
    elseif sel == 2 then
      mawr = (mawr + 1) & 0xFFFF
    end
  end
end, emu.callbackType.write, 0x0000, 0x03FF, CPU, MEM)

local function cddaRendererNow()
  return r(STATE) == 2 and r(TIMER) == 0x38
end

-- ★ 스크립트를 로드한 직후 CPU $5B80에는 ADPCM renderer가 있을 수 있다.
-- CD-DA state=1 뒤 resident가 CD-DA 이미지를 복사한 다음에야 $5DDA=$38,
-- JSR $6463 위치는 .48/.53에서 다르므로, active CD-DA 이미지에서 직접 찾는다.
-- 따라서 여기서 미리 검사하면 첫 로그처럼 영구 비활성화된다.
-- renderer가 VDC를 만지기 전의 상태를 매 호출마다 새로 잡는다.
emu.addMemoryCallback(function()
  if disabled then return end
  active = cddaRendererNow()
  saved = active and snapshot() or nil
  vdcDirty = false
  if active then
    if not layoutChecked then
      local matches = {}
      for at = ENG_LO, ENG_HI - 2 do
        if r(at) == 0x20 and r(at + 1) == 0x63 and r(at + 2) == 0x64 then
          matches[#matches + 1] = at
        end
      end
      if r(0x5B80) ~= 0x53 or r(0x5B81) ~= 0x55 or r(0x5B82) ~= 0x42 or #matches ~= 1 then
        disabled, skipped = true, 1
        emu.log('SUB 0.5.87 STOP: active CD-DA renderer layout differs; no writes installed')
        active, saved = false, nil
        return
      end
      pushCall = matches[1]
      layoutChecked = true
      emu.log(string.format('SUB 0.5.87 active CD-DA renderer verified; game push at $%04X', pushCall))
    end
    calls = calls + 1
  end
end, emu.callbackType.exec, ENTRY, ENTRY, CPU, MEM)

-- ★ 바로 다음 JSR $6463은 게임 코드다. RTS에서 복원하면 게임이 renderer가
-- 남긴 MAWR로 이미 쓴 뒤라 늦다. 따라서 게임으로 제어를 넘기기 직전에 복원한다.
emu.addMemoryCallback(function(address)
    if address ~= pushCall or disabled or not active or not saved or not cddaRendererNow() then return end
    local before = snapshot()
    if not vdcDirty or (before.sel == saved.sel and before.mawr == saved.mawr
        and before.inc == saved.inc) then
      cleanReturns = cleanReturns + 1
      active, saved, vdcDirty = false, nil, false
      return
    end
    repairing = true
    emu.write(0x0000, 0x00, MEM)
    emu.write(0x0002, saved.mawr & 0xFF, MEM)
    emu.write(0x0003, saved.mawr >> 8, MEM)
    emu.write(0x0000, saved.sel, MEM)
    repairing = false
    -- programmatic port write가 callback 이력에 반영되지 않는 Mesen 버전도 있어
    -- 디코더를 명시적으로 같은 상태로 맞춘다. CR은 renderer가 건드리지 않는다.
    sel, mawr = saved.sel, saved.mawr
    restores = restores + 1
    local after = snapshot()
    if after.sel ~= saved.sel or after.mawr ~= saved.mawr or after.inc ~= saved.inc then
      mismatch = mismatch + 1
      emu.log(string.format('SUB 0.5.87 FAIL restore f=%d want %s got %s', frame, fmt(saved), fmt(after)))
    elseif restores <= 3 then
      emu.log(string.format('SUB 0.5.87 restore #%d f=%d  %s -> %s', restores, frame, fmt(before), fmt(after)))
    end
    active, saved, vdcDirty = false, nil, false
end, emu.callbackType.exec, ENG_LO, ENG_HI, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  if frame % 1800 == 0 then
    emu.log(string.format('SUB 0.5.87 f=%d calls=%d restores=%d clean=%d mismatch=%d',
      frame, calls, restores, cleanReturns, mismatch))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  emu.log(string.format('SUB 0.5.87 end calls=%d restores=%d clean=%d mismatch=%d skipped=%d',
    calls, restores, cleanReturns, mismatch, skipped))
end, emu.eventType.scriptEnded)

emu.log('SUB 0.5.87 CD-DA VDC return POC armed -- waits for active CD-DA renderer')
