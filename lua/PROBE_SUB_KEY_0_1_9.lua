-- PROBE_SUB_KEY 0.1.9 -- ADPCM 자막 식별값 측정 전용. 화면/RAM/VRAM을 절대 쓰지 않는다.
--
-- 끝주소 충돌(예: 6000/0E)이 타이틀 효과음과 접수처 대사를 같은 것으로 만들었다.
-- 이 판은 ADPCM 시작 프레임의 CD 상태를 그대로 남겨 sector가 구분 키가 될 수 있는지
-- 확인한다. 자막 엔진을 올리지 않으므로 UI를 깨지 않는다.

local MEM = emu.memType.pceMemory
local lines, frame, was_playing = {}, 0, false

local function say(s)
  emu.log(s)
  lines[#lines + 1] = s
end

local function scalar(v)
  local t = type(v)
  return t == 'number' or t == 'string' or t == 'boolean'
end

local function cd_snapshot(state)
  local keys = {}
  for k, v in pairs(state) do
    if type(k) == 'string' and k:lower():find('cdrom', 1, true) and scalar(v) then
      keys[#keys + 1] = k
    end
  end
  table.sort(keys)
  local out = {}
  for _, k in ipairs(keys) do out[#out + 1] = k .. '=' .. tostring(state[k]) end
  return table.concat(out, ' | ')
end

local function flush()
  local f = io.open(string.format('C:/snatcher/dump/probe_sub_key_0_1_9_%s.tsv',
                                  os.date('%Y%m%d_%H%M%S')), 'w')
  if not f then return end
  f:write('line\n')
  for _, line in ipairs(lines) do f:write(line .. '\n') end
  f:close()
end

emu.addEventCallback(function()
  frame = frame + 1
  local state = emu.getState()
  local playing = state['cdrom.adpcm.playing'] == true
  if playing and not was_playing then
    local read = state['cdrom.adpcm.readAddress'] or 0
    local length = state['cdrom.adpcm.adpcmLength'] or 0
    local rate = state['cdrom.adpcm.playbackRate'] or 0
    local ending = (read + length) % 0x10000
    say(string.format('[%d] ADPCM START end=%04X rate=%02X read=%04X len=%04X',
                      frame, ending, rate, read, length))
    say('  ' .. cd_snapshot(state))
    flush()
  elseif not playing and was_playing then
    say(string.format('[%d] ADPCM END', frame))
  end
  was_playing = playing
end, emu.eventType.startFrame)

emu.log('PROBE_SUB_KEY 0.1.9 loaded -- measurement only; no subtitle engine is installed')
emu.log('  Run title -> reception once, then send the newest dump/probe_sub_key_0_1_9_*.tsv')
