-- SUB 0.4.56-fec4-transition-audit -- $FEC4 전환 순간 이중 키 비교
--
-- actual: Mesen cdrom.adpcm 상태의 end/rate
-- gate:   게임 RAM $22A6/$22A7/$22AA의 end/rate
-- 두 주소로 ADPCM RAM 표본까지 각각 읽어 6 B 키를 비교한다.
-- AC 업로드 외 게임 메모리 write 0 B. controller/allocator/wipe 없음.

dofile('C:/snatcher/lua/SUB/0.4.54-ac-upload-only.lua')

local MEM, APCM = emu.memType.pceMemory, emu.memType.pceAdpcmRam
local CPU, GATE = emu.cpuType.pce, 0xFEC4

local function number(state, name)
  local value = state[name]
  return type(value) == 'number' and math.floor(value) or 0
end

local function keyAt(finish, rate)
  -- 표본 자리는 이대로 **고정**한다 (build_voice_console_keys.py 와 같아야 한다).
  -- 옮겨서 충돌을 줄이려는 시도는 2026-09-02 에 실패했다 -- 버퍼 앞쪽 자리는
  -- 클립 범위 밖이라 산출이 1,211 -> 1,022 로 줄어든다.  그쪽 주석 참고.
  local a1, a2, a3 = finish // 4, finish // 2, (finish * 5) // 8
  return string.format('%02X%02X%02X%02X%02X%02X',
    finish & 0xFF, finish >> 8, rate & 0xFF,
    emu.read(a1, APCM) or 0, emu.read(a2, APCM) or 0,
    emu.read(a3, APCM) or 0)
end

local lastPair, calls, changes, mismatches = nil, 0, 0, 0
emu.addMemoryCallback(function()
  calls = calls + 1
  local ok, state = pcall(emu.getState)
  if not ok or not state then return end

  local playing = state['cdrom.adpcm.playing'] == true
  local actual = '-'
  if playing then
    local finish = (number(state, 'cdrom.adpcm.readAddress') +
                    number(state, 'cdrom.adpcm.adpcmLength')) & 0xFFFF
    actual = keyAt(finish, number(state, 'cdrom.adpcm.playbackRate'))
  end

  local gateFinish = (emu.read(0x22A6, MEM) or 0) |
                     ((emu.read(0x22A7, MEM) or 0) << 8)
  local gateRate = emu.read(0x22AA, MEM) or 0
  local gateKey = keyAt(gateFinish, gateRate)
  local pair = actual .. '/' .. gateKey
  if pair == lastPair then return end
  lastPair, changes = pair, changes + 1
  local mismatch = actual ~= '-' and actual ~= gateKey
  if mismatch then mismatches = mismatches + 1 end
  emu.log(string.format(
    'SUB 0.4.56 TRANS #%d call=%d actual=%s gate=%s%s state=%02X ad=%02X',
    changes, calls, actual, gateKey, mismatch and ' ★ MISMATCH' or '',
    emu.read(0x7FDF, MEM) or 0, emu.read(0x180D, MEM) or 0))
end, emu.callbackType.exec, GATE, GATE, CPU, MEM)

emu.log('SUB 0.4.56-fec4-transition-audit loaded -- READ-ONLY TRANSITION PROBE')
emu.log('  actual key vs $22A6/$22A7/$22AA gate key · game write 0 B')
emu.log('  자막이 안 나오는 것이 정상 · 6800 전후 TRANS 로그와 진행 여부 확인')
