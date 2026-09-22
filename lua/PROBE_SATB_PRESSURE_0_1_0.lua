-- PROBE_SATB_PRESSURE 0.1.0 -- SATB 64엔트리 점유량을 읽기만 한다.
-- 화면/RAM/VRAM에 쓰지 않는다. Sprite Viewer의 한 프레임 대신 장면 전체의 최대치를 남긴다.

local VRAM = emu.memType.pceVideoRam
local SATB, ENTRIES, WORDS_PER_ENTRY = 0x1000, 64, 4
local frame, max_used, last_used = 0, 0, nil
local samples = {}

local function count_satb()
  local used, visible = 0, 0
  for i = 0, ENTRIES - 1 do
    local at = SATB + i * WORDS_PER_ENTRY
    local y = emu.read(at, VRAM) or 0
    local x = emu.read(at + 1, VRAM) or 0
    local pat = emu.read(at + 2, VRAM) or 0
    local attr = emu.read(at + 3, VRAM) or 0
    -- 네 워드가 모두 0인 엔트리는 게임이 조립하지 않은 빈 SATB 슬롯이다.
    if (y | x | pat | attr) ~= 0 then
      used = used + 1
      -- PCE SATB 좌표는 화면 원점에 각각 +64/+32가 붙는다. 큰 스프라이트의
      -- 크기는 여기서 세지 않으며, 화면 근방인지 보는 보조 지표다.
      local sy, sx = (y & 0x03FF) - 64, (x & 0x03FF) - 32
      if sy > -64 and sy < 240 and sx > -64 and sx < 320 then visible = visible + 1 end
    end
  end
  return used, visible
end

local function note(reason, used, visible)
  samples[#samples + 1] = string.format('%d\t%d\t%d\t%s', frame, used, visible, reason)
  emu.log(string.format('SATB frame %d: %d/64 occupied · near-screen %d  %s',
                        frame, used, visible, reason))
end

local function flush()
  local f = io.open(string.format('C:/snatcher/dump/probe_satb_pressure_0_1_0_%s.tsv',
                                  os.date('%Y%m%d_%H%M%S')), 'w')
  if not f then return end
  f:write('frame\toccupied\tnear_screen\treason\n')
  for _, row in ipairs(samples) do f:write(row .. '\n') end
  f:close()
end

emu.addEventCallback(function()
  frame = frame + 1
  local used, visible = count_satb()
  if used > max_used then
    max_used = used
    note('new_max', used, visible)
  elseif used ~= last_used then
    note('changed', used, visible)
  elseif frame % 600 == 0 then
    note('heartbeat', used, visible)
  end
  last_used = used
  if frame % 3600 == 0 then flush() end
end, emu.eventType.startFrame)

emu.log('PROBE_SATB_PRESSURE 0.1.0 loaded -- read-only SATB sampler')
emu.log('  logs occupied SATB slots (out of 64) and a near-screen reference count')
