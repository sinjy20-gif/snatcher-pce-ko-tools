-- SUB 0.5.75 -- BIOS 0.4.6.48 노스킵 화면 깨짐 판별기 (read-only)
--
-- CD-DA Track 17이 빌리는 VRAM $7900-$7DBF를 시작/종료에 비교하고,
-- 재생 중 게임이 같은 창을 다시 썼는지 VDC 포트에서 재구성한다.
-- 접수처 $66E5 -> $FFD4 -> bank1 $F054 -> $F08A 복구 체인도 함께 센다.
-- 메모리/VRAM/AC/state/키 입력은 전혀 쓰지 않는다.

local VERSION = '0.5.75'
local TAG = 'SUB ' .. VERSION
local MEM, VRAM, AC, CPU = emu.memType.pceMemory, emu.memType.pceVideoRam,
  emu.memType.pceArcadeCardRam, emu.cpuType.pce
local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/sub/noskip_vram_0_5_75_' .. STAMP .. '.tsv'
local out = assert(io.open(OUT, 'w'), 'cannot open ' .. OUT)

local STATE = 0x7FDF
local CDDA_START, CDDA_FINISH = 0xF798, 0x5E16
local VRAM_FIRST, VRAM_LAST = 0x7900, 0x7DBF       -- word addresses
local VRAM_BYTE, VRAM_BYTES = VRAM_FIRST * 2, (VRAM_LAST - VRAM_FIRST + 1) * 2
local HELPER_CTL_BASE = 0x1F1C00 + 432 + 4

local frame = 0
local cdda = false
local selReg, mawr, dataLo = 0, 0, 0
local snapStart, snapBeforeRestore, snapAfterRestore
local writes = { engine=0, game=0, unknown=0 }
local firstGamePc, lastGamePc = nil, nil
local hits = { hook=0, exit=0, dispatch=0, repair=0, finish=0, state3=0, state0=0 }
local afterRestoreAt = nil

local function rb(at, kind) return emu.read(at, kind or MEM) or 0 end
local function pcNow()
  local ok, s = pcall(emu.getState)
  if not ok or type(s) ~= 'table' then return -1 end
  for _, key in ipairs({ 'cpu.pc', 'pc' }) do
    if type(s[key]) == 'number' then return math.floor(s[key]) & 0xFFFF end
  end
  return -1
end

-- 두 개의 가벼운 checksum. 같으면 byte-for-byte 확인까지 수행한다.
local function snapshot()
  local bytes, sum, mix = {}, 0, 0
  for i = 0, VRAM_BYTES - 1 do
    local v = rb(VRAM_BYTE + i, VRAM) & 0xFF
    bytes[i + 1] = v
    sum = (sum + v) & 0xFFFFFFFF
    mix = ((mix << 5) ~ (mix >> 27) ~ v ~ i) & 0xFFFFFFFF
  end
  return { bytes=bytes, sum=sum, mix=mix }
end

local function diff(a, b)
  if not a or not b then return -1 end
  local n = 0
  for i = 1, VRAM_BYTES do if a.bytes[i] ~= b.bytes[i] then n = n + 1 end end
  return n
end

local function sig(s)
  if not s then return '--------/--------' end
  return string.format('%08X/%08X', s.sum, s.mix)
end

local function helperBase()
  local lo, hi, bank, first = rb(HELPER_CTL_BASE, AC), rb(HELPER_CTL_BASE + 1, AC),
    rb(HELPER_CTL_BASE + 2, AC), rb(HELPER_CTL_BASE + 3, AC)
  return string.format('%02X%02X/%02X/%02X', hi, lo, bank, first)
end

local function emit(event, detail)
  local line = string.format('%d\t%s\tpc=%04X\tstate=%02X\thelper=%s\t%s',
    frame, event, pcNow() & 0xFFFF, rb(STATE), helperBase(), detail or '')
  out:write(line .. '\n'); out:flush()
  emu.log(TAG .. ' ' .. line:gsub('\t', ' · '))
end

local function exec(at, name, key, limit)
  emu.addMemoryCallback(function()
    hits[key] = hits[key] + 1
    if hits[key] <= (limit or 8) then emit(name, 'hit=' .. hits[key]) end
  end, emu.callbackType.exec, at, at, CPU, MEM)
end

exec(0x66E5, 'RECEPTION_HOOK', 'hook', 8)
exec(0x66F8, 'RECEPTION_EXIT', 'exit', 8)
exec(0xF054, 'RECEPTION_DISPATCH', 'dispatch', 8)
exec(0xF08A, 'RECEPTION_REPAIR', 'repair', 8)

emu.addMemoryCallback(function()
  cdda = true
  writes = { engine=0, game=0, unknown=0 }
  firstGamePc, lastGamePc = nil, nil
  snapStart = snapshot()
  snapBeforeRestore, snapAfterRestore, afterRestoreAt = nil, nil, nil
  emit('CDDA_START', 'vram=' .. sig(snapStart))
end, emu.callbackType.exec, CDDA_START, CDDA_START, CPU, MEM)

emu.addMemoryCallback(function()
  hits.finish = hits.finish + 1
  snapBeforeRestore = snapshot()
  emit('CDDA_FINISH', string.format(
    'vram=%s diffStart=%d writesEngine=%d writesGame=%d writesUnknown=%d gamePc=%s-%s',
    sig(snapBeforeRestore), diff(snapStart, snapBeforeRestore), writes.engine,
    writes.game, writes.unknown, firstGamePc and string.format('%04X', firstGamePc) or '----',
    lastGamePc and string.format('%04X', lastGamePc) or '----'))
end, emu.callbackType.exec, CDDA_FINISH, CDDA_FINISH, CPU, MEM)

emu.addMemoryCallback(function(_address, value)
  value = (value or 0) & 0xFF
  if value == 3 and cdda then
    hits.state3 = hits.state3 + 1
    if not snapBeforeRestore then snapBeforeRestore = snapshot() end
    emit('STATE3', 'beforeRestore=' .. sig(snapBeforeRestore))
  elseif value == 0 and cdda and hits.state3 > 0 then
    hits.state0 = hits.state0 + 1
    afterRestoreAt = frame + 2
    emit('STATE0', 'restore scheduled; sample in 2 frames')
  end
end, emu.callbackType.write, STATE, STATE, CPU, MEM)

-- pceVideoRam write callback이 없으므로 VDC register/data port를 복원한다.
local function onVdcWrite(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF
  if port == 0 then
    selReg = value
  elseif port == 2 then
    dataLo = value
    if selReg == 0 then mawr = (mawr & 0xFF00) | value end
  elseif port == 3 then
    if selReg == 0 then
      mawr = (mawr & 0x00FF) | (value << 8)
    elseif selReg == 2 then
      local word = mawr & 0x7FFF
      if cdda and word >= VRAM_FIRST and word <= VRAM_LAST then
        local pc = pcNow()
        if pc >= 0x5B80 and pc <= 0x5E1E then
          writes.engine = writes.engine + 1
        elseif pc >= 0 then
          writes.game = writes.game + 1
          if not firstGamePc then firstGamePc = pc end
          lastGamePc = pc
        else
          writes.unknown = writes.unknown + 1
        end
      end
      mawr = (mawr + 1) & 0xFFFF
    end
  end
end

local installed = pcall(function()
  emu.addMemoryCallback(onVdcWrite, emu.callbackType.write, 0x0000, 0x03FF, CPU, MEM)
end)

local function summary(tag)
  local stale = 'WAIT'
  if snapAfterRestore then
    local back = diff(snapStart, snapAfterRestore)
    local newer = diff(snapBeforeRestore, snapAfterRestore)
    if writes.game > 0 and back == 0 then stale = 'STALE-RESTORE'
    elseif back == 0 then stale = 'RESTORED'
    else stale = 'CHANGED' end
    emit(tag, string.format(
      'result=%s start->after=%d before->after=%d writesGame=%d hook/exit/dispatch/repair=%d/%d/%d/%d',
      stale, back, newer, writes.game, hits.hook, hits.exit, hits.dispatch, hits.repair))
  else
    emit(tag, string.format('result=%s writesGame=%d hook/exit/dispatch/repair=%d/%d/%d/%d',
      stale, writes.game, hits.hook, hits.exit, hits.dispatch, hits.repair))
  end
end

emu.addEventCallback(function()
  frame = frame + 1
  if afterRestoreAt and frame >= afterRestoreAt and not snapAfterRestore then
    snapAfterRestore = snapshot()
    cdda = false
    summary('RESTORE_CHECK')
  end
  if frame % 1200 == 0 then
    emit('HEARTBEAT', string.format('cdda=%s writes=%d/%d repair=%d',
      cdda and 'ON' or 'OFF', writes.engine, writes.game, hits.repair))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  summary('END')
  out:close()
end, emu.eventType.scriptEnded)

out:write('frame\tevent\tpc\tstate\thelper\tdetail\n'); out:flush()
emu.log(TAG .. ' loaded -- BIOS 0.4.6.48 no-skip VRAM/reception read-only probe')
emu.log('  Power Cycle 뒤 스킵 없이 접수처까지 · 키/메모리/VRAM/AC/state 쓰기 없음')
emu.log('  CD-DA $7900-$7DBF stale restore + 접수처 복구 체인을 자동 판정')
emu.log('  VDC decoder=' .. (installed and 'ON' or 'FAIL') .. ' · 결과: ' .. OUT)
