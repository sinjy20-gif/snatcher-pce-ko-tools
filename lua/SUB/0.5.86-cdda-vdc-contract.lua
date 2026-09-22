-- SUB 0.5.86 -- CD-DA renderer의 VDC 반환 ABI 수집기
--
-- 쓰기 없음: CPU RAM / VRAM / AC / state / 입력을 전혀 바꾸지 않는다.
-- 목적: 새 CD-DA 트랙을 활성화하기 전에 renderer 진입/반환의 VDC 상태를
--       track별로 수집한다. MAWR은 read-back 불가이므로 VDC 포트 write를
--       해석한 값이며, 같은 트랙의 여러 조합이 나오면 그 트랙은 계약 등록 금지다.

local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce
local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH = 'C:/snatcher/dump/cdda_vdc_contract_0_5_86_' .. STAMP .. '.tsv'
local out = assert(io.open(PATH, 'w'))
out:write('frame\tevent\ttrack\tdetail\n')

local frame, sel, mawr, crHi = 0, 0, 0, 0
local inEngine, cddaCall = false, false
local seenEntry, seenExit = {}, {}
local function incr() return ({[0]='+1',[1]='+32',[2]='+64',[3]='+128'})[(crHi >> 3) & 3] end
local function state() return string.format('sel=$%02X mawr=$%04X inc=%s', sel, mawr & 0x7FFF, incr()) end
local function track() return (emu.read(0x26F9, MEM) or 0) & 0x7F end
local function rec(event, tr, detail)
  out:write(string.format('%d\t%s\t%d\t%s\n', frame, event, tr, detail)); out:flush()
end

-- 현행/향후 공통 CD-DA renderer 표식: state=2 및 timer 첫 opcode SEC($38).
-- 이 조건이 아니면 ADPCM renderer를 세지 않는다.
emu.addMemoryCallback(function(address)
  if not inEngine then
    inEngine = true
    cddaCall = (emu.read(0x7FDF, MEM) or 0) == 2 and (emu.read(0x5DDA, MEM) or 0) == 0x38
    if cddaCall then
      local tr, k = track(), state()
      local id = tr .. '|' .. k
      if not seenEntry[id] then seenEntry[id] = true; rec('entry_new', tr, k) end
    end
  end
  if (emu.read(address, MEM) or 0) == 0x60 and inEngine then
    if cddaCall then
      local tr, k = track(), state()
      local id = tr .. '|' .. k
      if not seenExit[id] then seenExit[id] = true; rec('exit_new', tr, k) end
    end
    inEngine, cddaCall = false, false
  end
end, emu.callbackType.exec, 0x5B80, 0x5E1E, CPU, MEM)

emu.addMemoryCallback(function(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF
  if port == 0 then
    sel = value
  elseif port == 2 and sel == 0 then
    mawr = (mawr & 0xFF00) | value
  elseif port == 3 then
    if sel == 0 then mawr = (mawr & 0x00FF) | (value << 8)
    elseif sel == 5 then crHi = value
    elseif sel == 2 then mawr = (mawr + 1) & 0xFFFF end
  end
end, emu.callbackType.write, 0x0000, 0x03FF, CPU, MEM)

emu.addEventCallback(function() frame = frame + 1 end, emu.eventType.endFrame)
emu.addEventCallback(function()
  out:close()
  emu.log('SUB 0.5.86 saved: ' .. PATH)
end, emu.eventType.scriptEnded)

emu.log('SUB 0.5.86 CD-DA VDC contract probe armed -- read-only')
