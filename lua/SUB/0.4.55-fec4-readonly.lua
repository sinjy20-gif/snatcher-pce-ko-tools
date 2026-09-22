-- SUB 0.4.55-fec4-readonly -- AC 업로드 + $FEC4 읽기 전용 callback
--
-- 0.4.54의 팩/엔진 AC 업로드 뒤, 실제 controller와 같은 $FEC4 지점에서
-- 음성 키만 읽는다. callback 안에서는 어떤 메모리에도 쓰지 않는다.
-- Power Cycle 뒤 다른 SUB Lua 없이 이 파일 하나만 실행할 것.

dofile('C:/snatcher/lua/SUB/0.4.54-ac-upload-only.lua')

local MEM, APCM = emu.memType.pceMemory, emu.memType.pceAdpcmRam
local CPU, GATE, STATE = emu.cpuType.pce, 0xFEC4, 0x7FDF

local function number(state, name)
  local value = state[name]
  return type(value) == 'number' and math.floor(value) or 0
end

local function actualKey()
  local ok, state = pcall(emu.getState)
  if not ok or not state or state['cdrom.adpcm.playing'] ~= true then return nil end
  local finish = (number(state, 'cdrom.adpcm.readAddress') +
                  number(state, 'cdrom.adpcm.adpcmLength')) & 0xFFFF
  local rate = number(state, 'cdrom.adpcm.playbackRate') & 0xFF
  -- 표본 자리는 이대로 **고정**한다 (build_voice_console_keys.py 와 같아야 한다).
  -- 옮겨서 충돌을 줄이려는 시도는 2026-09-02 에 실패했다 -- 버퍼 앞쪽 자리는
  -- 클립 범위 밖이라 산출이 1,211 -> 1,022 로 줄어든다.  그쪽 주석 참고.
  local a1, a2, a3 = finish // 4, finish // 2, (finish * 5) // 8
  return string.format('%02X%02X%02X%02X%02X%02X',
    finish & 0xFF, finish >> 8, rate,
    emu.read(a1, APCM) or 0, emu.read(a2, APCM) or 0,
    emu.read(a3, APCM) or 0)
end

local held, seen = nil, 0
emu.addMemoryCallback(function()
  local key = actualKey()
  if not key then
    held = nil
  elseif key ~= held then
    held, seen = key, seen + 1
    emu.log(string.format(
      'SUB 0.4.55 FEC4 READ ONLY #%d key=%s state=%02X gate=%02X%02X_%02X',
      seen, key, emu.read(STATE, MEM) or 0,
      emu.read(0x22A6, MEM) or 0, emu.read(0x22A7, MEM) or 0,
      emu.read(0x22AA, MEM) or 0))
  end
end, emu.callbackType.exec, GATE, GATE, CPU, MEM)

emu.log('SUB 0.4.55-fec4-readonly loaded -- AC upload + FEC4 READ ONLY')
emu.log('  callback write 0 B · selector/state/legacy gate/VRAM 무수정')
emu.log('  자막이 안 나오는 것이 정상 · 접수처 진행 여부만 확인')
