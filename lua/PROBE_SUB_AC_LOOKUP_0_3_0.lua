-- PROBE_SUB_AC_LOOKUP 0.3.0
-- Lua는 ADPCM 선택 토큰만 전달하고, 엔진이 AC 팩 색인에서 레코드를 직접 찾는다.

local MEM = emu.memType.pceMemory
local AC = emu.memType.pceArcadeCardRam
local VRAM = emu.memType.pceVideoRam
local ENGINE_AT, STUB_AT, PACK_AT = 0x5B80, 0x7FA0, 0x1C0000
local PAT_VRAM, VRAM_WORDS = 0x7900, 19 * 0x40
local TARGET_SECTOR, TARGET_END, TARGET_RATE = 0x003078, 0x6800, 0x0E
-- engine_ac_lookup_poc.json의 생성 오프셋
local OFF_READY, OFF_COUNT, OFF_SELECTOR, OFF_RECORD = 367, 368, 369, 464
local ENGINE_PATH = 'C:/snatcher/build/cutscene_subs/engine_ac_lookup_poc.bin'
local PACK_PATH = 'C:/snatcher/build/cutscene_subs/subtitle_pack.bin'

local function slurp(path)
  local f = assert(io.open(path, 'rb'), 'cannot open ' .. path)
  local data = f:read('*a'); f:close()
  local out = {}; for i = 1, #data do out[i] = data:byte(i) end
  return out
end

local engine, pack = slurp(ENGINE_PATH), slurp(PACK_PATH)
local function u8(o) return pack[o + 1] end
local function u16(o) return u8(o) | (u8(o + 1) << 8) end
local function u32(o) return u16(o) | (u16(o + 2) << 16) end
assert(#engine <= 704 and u8(0) == 0x53 and u8(1) == 0x4E and
       u8(2) == 0x53 and u8(3) == 0x42 and u16(4) == 5,
       'engine or host SNSB v5 pack is invalid')
for i = 0, 5 do
  assert((emu.read(PACK_AT + i, AC) or -1) == u8(i),
         'AC pack differs; run LOAD_SUBTITLE_PACK_AC_0_1_0.lua again')
end

local P = { adpcm_count = u16(14), adpcm_off = u32(16), record_off = u32(26),
            char_off = u32(38), stride = u8(42), cell_bytes = u8(35) }

local function record_text(rec)
  local at, text = P.record_off + rec, ''
  for i = 0, u8(at) - 1 do
    local cell = at + 6 + i * P.cell_bytes
    text = text .. utf8.char(u16(P.char_off + u16(cell) * 2))
  end
  return text
end

local parts = {}
for i = 0, P.adpcm_count - 1 do
  local at = P.adpcm_off + i * P.stride
  local sector = u8(at) | (u8(at + 1) << 8) | (u8(at + 2) << 16)
  if sector == TARGET_SECTOR and u16(at + 3) == TARGET_END and u8(at + 5) == TARGET_RATE then
    parts[#parts + 1] = { at = at, start_frame = u16(at + 7), rec = u32(at + 9) }
  end
end
assert(#parts > 0, 'target voice is not in subtitle pack')

local frames, was_playing, armed, checked = 0, false, false, false
local voice_start, part_index, inspect_at, expected_rec = 0, 0, 0, 0
local backup = nil

local function stub_ok()
  return emu.read(STUB_AT, MEM) == 0x08 and emu.read(0x601E, MEM) == 0x20
end
local function vram_save()
  backup = {}; for i = 0, VRAM_WORDS - 1 do backup[i] = emu.read(PAT_VRAM + i, VRAM) or 0 end
end
local function vram_restore()
  if not backup then return end
  for i = 0, VRAM_WORDS - 1 do emu.write(PAT_VRAM + i, backup[i], VRAM) end
  backup = nil
end

local function select_part(index)
  local part = parts[index]
  -- sector3 + end2 + rate + flags + start_frame2 = 색인 앞 9 B
  for i = 0, 8 do emu.write(ENGINE_AT + OFF_SELECTOR + i, u8(part.at + i), MEM) end
  emu.write(ENGINE_AT + OFF_READY, 0, MEM)
  expected_rec, inspect_at = part.rec, frames + 8
  emu.log(string.format('  조각 %d/%d +%df · 색인 토큰 9 B + ready 1 B · "%s"',
                        index, #parts, part.start_frame, record_text(part.rec)))
end

local function stage()
  vram_save()
  for i = 1, #engine do emu.write(ENGINE_AT + i - 1, engine[i], MEM) end
  armed, voice_start, part_index = true, frames, 1
  emu.log(string.format('[%d] AC LOOKUP START · 엔진 %d B 설치', frames, #engine))
  select_part(1)
end

local function loaded_text()
  local count, text = emu.read(ENGINE_AT + OFF_COUNT, MEM) or 0, ''
  for i = 0, count - 1 do
    local at = ENGINE_AT + OFF_RECORD + 6 + i * 4
    local id = (emu.read(at, MEM) or 0) | ((emu.read(at + 1, MEM) or 0) << 8)
    text = text .. utf8.char(u16(P.char_off + id * 2))
  end
  return text
end

local function inspect()
  local ready = emu.read(ENGINE_AT + OFF_READY, MEM) or 0
  local actual, expected = loaded_text(), record_text(expected_rec)
  local nonzero = false
  for i = 0, 63 do
    if (emu.read(PAT_VRAM + i, VRAM) or 0) ~= 0 then nonzero = true; break end
  end
  emu.log(string.format('    검사: ready=%d · VRAM=%s · 찾은 글="%s"',
                        ready, nonzero and '있음' or '없음', actual))
  if ready == 1 and nonzero and actual == expected then
    emu.log('    ★ AC LOOKUP PASS: 엔진이 ADPCM 색인에서 정확한 레코드를 찾았다')
  else
    emu.log(string.format('    ★ AC LOOKUP FAIL: 기대="%s"', expected))
  end
end

local function disarm()
  for i = 0, 2 do emu.write(ENGINE_AT + i, 0, MEM) end
  armed = false; vram_restore()
  emu.log(string.format('[%d] AC LOOKUP END · VRAM %d 워드 복구', frames, VRAM_WORDS))
end

emu.addEventCallback(function()
  frames = frames + 1
  if not checked and stub_ok() then checked = true; emu.log('준비됨 -- 디스크 훅과 상주부 확인')
  elseif frames == 1800 and not checked then emu.log('★ subtitle_resident 디스크 훅이 없다') end
  if inspect_at > 0 and frames >= inspect_at then inspect_at = 0; inspect() end

  local state, playing = emu.getState(), false
  state = state or {}; playing = state['cdrom.adpcm.playing'] == true
  if playing and not was_playing then
    local ending = (((state['cdrom.adpcm.readAddress'] or 0) +
                     (state['cdrom.adpcm.adpcmLength'] or 0)) % 0x10000)
    if state['cdrom.scsi.sector'] == TARGET_SECTOR and ending == TARGET_END and
       (state['cdrom.adpcm.playbackRate'] or 0) == TARGET_RATE then stage() end
  elseif playing and armed then
    local elapsed, want = frames - voice_start, part_index
    for i = #parts, 1, -1 do if elapsed >= parts[i].start_frame then want = i; break end end
    if want ~= part_index then part_index = want; select_part(want) end
  elseif not playing and was_playing and armed then disarm() end
  was_playing = playing
end, emu.eventType.startFrame)

emu.log('PROBE_SUB_AC_LOOKUP 0.3.0 loaded')
emu.log(string.format('  AC SNSB v5 · 엔진 %d B · ADPCM 색인 %d개 · 대상 조각 %d개',
                      #engine, P.adpcm_count, #parts))
emu.log('  엔진이 AC 색인을 선형 검색한다; Lua는 레코드 주소를 전달하지 않는다')
