-- SUB 0.4.53-readonly-key-audit -- 게임 무수정 음성 키 기준시험
--
-- 게임 RAM / AC RAM / VRAM / Sprite RAM에 쓰기 0 B.
-- memory exec callback도 등록하지 않는다. endFrame에서 Mesen 상태와 ADPCM RAM을
-- 읽어 현재 음성의 6 B 키가 정본 902키 표에 있는지만 기록한다.
-- Power Cycle 뒤 다른 SUB Lua 없이 이 파일 하나만 실행할 것.

local VERSION = '0.4.53-readonly-key-audit'
local APCM = emu.memType.pceAdpcmRam
local MAP = 'C:/snatcher/build/cutscene_subs/subtitle_runtime_key_map.tsv'
local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/sub_0_4_53_readonly_key_' .. STAMP .. '.tsv'

local known = {}
do
  local f = assert(io.open(MAP, 'r'), 'cannot open ' .. MAP)
  for line in f:lines() do
    local key = line:match('^([0-9A-F]+)\t')
    if key then known[key] = (known[key] or 0) + 1 end
  end
  f:close()
end

local out = assert(io.open(OUT, 'w'))
out:write('frame\ttime\tevent\tkey\tfragments\n')
out:flush()

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
    emu.read(a1, APCM) or 0,
    emu.read(a2, APCM) or 0,
    emu.read(a3, APCM) or 0)
end

local frame, seen, held = 0, 0, nil
local keys, misses, current = 0, 0, '-'

emu.addEventCallback(function()
  frame = frame + 1
  local key = actualKey()
  if not key then
    held = nil
  elseif key ~= held then
    held, current, seen = key, key, seen + 1
    local fragments = known[key] or 0
    local event
    if fragments > 0 then
      event, keys = 'KEY', keys + 1
    else
      event, misses = 'MISS', misses + 1
    end
    local line = string.format('%d\t%s\t%s\t%s\t%d\n',
      frame, os.date('%H:%M:%S'), event, key, fragments)
    out:write(line); out:flush()
    emu.log(string.format('SUB 0.4.53 READ ONLY ★ %s #%d %s · %d조각',
                          event, seen, key, fragments))
  end

  emu.drawString(4, 4,
    string.format('0.4.53 READ ONLY  KEY:%d MISS:%d  %s', keys, misses, current),
    0x40FF40, 0x000000)
end, emu.eventType.endFrame)

emu.log('SUB ' .. VERSION .. ' loaded -- ZERO GAME WRITES')
emu.log('  memory callback 0 · RAM/AC/VRAM/Sprite RAM write 0 B')
emu.log('  lookup: 902키 / output: ' .. OUT)
emu.log('  Power Cycle 뒤 이 파일 하나만 실행')
