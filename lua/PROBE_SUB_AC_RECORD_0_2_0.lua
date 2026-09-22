-- PROBE_SUB_AC_RECORD 0.2.0
-- 엔진이 AC 팩의 임의 레코드(헤더·셀)와 글리프를 직접 읽는 POC.
-- Lua는 음성을 감지하고 조각이 바뀔 때 AC 레코드 주소 3 B + ready 1 B만 쓴다.

local MEM = emu.memType.pceMemory
local AC = emu.memType.pceArcadeCardRam
local VRAM = emu.memType.pceVideoRam

local ENGINE_AT, STUB_AT = 0x5B80, 0x7FA0
local PACK_AT = 0x1C0000
local PAT_VRAM, VRAM_WORDS = 0x7900, 19 * 0x40
local TARGET_SECTOR, TARGET_END, TARGET_RATE = 0x003078, 0x6800, 0x0E
-- engine_ac_record_poc.json에서 생성된 오프셋. 빌더가 바뀌면 함께 확인한다.
local OFF_READY, OFF_RECORD_PTR = 313, 314
local ENGINE_PATH = 'C:/snatcher/build/cutscene_subs/engine_ac_record_poc.bin'
local PACK_PATH = 'C:/snatcher/build/cutscene_subs/subtitle_pack.bin'

local function slurp(path)
  local f = assert(io.open(path, 'rb'), 'cannot open ' .. path)
  local data = f:read('*a'); f:close()
  local out = {}
  for i = 1, #data do out[i] = data:byte(i) end
  return out
end

local engine, pack = slurp(ENGINE_PATH), slurp(PACK_PATH)
assert(#engine <= 704, string.format('engine too large: %d', #engine))

local function u8(o) return pack[o + 1] end
local function u16(o) return u8(o) | (u8(o + 1) << 8) end
local function u32(o) return u16(o) | (u16(o + 2) << 16) end

assert(u8(0) == 0x53 and u8(1) == 0x4E and u8(2) == 0x53 and u8(3) == 0x42,
       'host pack is not SNSB')
local version = u16(4)
assert(version == 5, string.format('host pack version %d, expected 5', version))
for i = 0, 3 do
  assert((emu.read(PACK_AT + i, AC) or -1) == u8(i),
         'AC pack missing; run LOAD_SUBTITLE_PACK_AC_0_1_0.lua first')
end
assert(((emu.read(PACK_AT + 4, AC) or 0) |
       ((emu.read(PACK_AT + 5, AC) or 0) << 8)) == version,
       'AC pack version differs from host pack; reload it')

local P = {
  adpcm_count = u16(14), adpcm_off = u32(16), record_off = u32(26),
  char_off = u32(38), stride = u8(42), cell_bytes = u8(35)
}

local function find_parts()
  local out = {}
  for i = 0, P.adpcm_count - 1 do
    local at = P.adpcm_off + i * P.stride
    local sector = u8(at) | (u8(at + 1) << 8) | (u8(at + 2) << 16)
    if sector == TARGET_SECTOR and u16(at + 3) == TARGET_END and
       u8(at + 5) == TARGET_RATE then
      out[#out + 1] = { start_frame = u16(at + 7), rec = u32(at + 9) }
    end
  end
  return out
end

local function record_text(rec)
  local at = P.record_off + rec
  local cells, text = u8(at), ''
  for i = 0, cells - 1 do
    local cell = at + 6 + i * P.cell_bytes
    text = text .. utf8.char(u16(P.char_off + u16(cell) * 2))
  end
  return text
end

local parts = find_parts()
assert(#parts > 0, 'target voice is not in subtitle pack')

local frames, was_playing = 0, false
local armed, checked = false, false
local voice_start, part_index = 0, 0
local backup, inspect_at, expected_ptr = nil, 0, 0

local function stub_ok()
  return emu.read(STUB_AT, MEM) == 0x08 and emu.read(0x601E, MEM) == 0x20
end

local function vram_save()
  backup = {}
  for i = 0, VRAM_WORDS - 1 do
    backup[i] = emu.read(PAT_VRAM + i, VRAM) or 0
  end
end

local function vram_restore()
  if not backup then return end
  for i = 0, VRAM_WORDS - 1 do emu.write(PAT_VRAM + i, backup[i], VRAM) end
  backup = nil
end

local function select_part(index)
  local part = parts[index]
  local address = PACK_AT + P.record_off + part.rec
  emu.write(ENGINE_AT + OFF_RECORD_PTR + 0, address & 0xFF, MEM)
  emu.write(ENGINE_AT + OFF_RECORD_PTR + 1, (address >> 8) & 0xFF, MEM)
  emu.write(ENGINE_AT + OFF_RECORD_PTR + 2, (address >> 16) & 0xFF, MEM)
  emu.write(ENGINE_AT + OFF_READY, 0, MEM)
  expected_ptr, inspect_at = address, frames + 8
  emu.log(string.format('  조각 %d/%d +%df · AC record $%06X · 제어 4 B · "%s"',
                        index, #parts, part.start_frame, address, record_text(part.rec)))
end

local function stage()
  vram_save()
  for i = 1, #engine do emu.write(ENGINE_AT + i - 1, engine[i], MEM) end
  armed, voice_start, part_index = true, frames, 1
  emu.log(string.format('[%d] AC RECORD START · 엔진 %d B 설치', frames, #engine))
  select_part(1)
end

local function inspect()
  local ready = emu.read(ENGINE_AT + OFF_READY, MEM) or 0
  local ptr = (emu.read(ENGINE_AT + OFF_RECORD_PTR, MEM) or 0) |
              ((emu.read(ENGINE_AT + OFF_RECORD_PTR + 1, MEM) or 0) << 8) |
              ((emu.read(ENGINE_AT + OFF_RECORD_PTR + 2, MEM) or 0) << 16)
  local nonzero = false
  for i = 0, 63 do
    if (emu.read(PAT_VRAM + i, VRAM) or 0) ~= 0 then nonzero = true; break end
  end
  emu.log(string.format('    검사: ready=%d · ptr=$%06X/%06X · VRAM=%s',
                        ready, ptr, expected_ptr, nonzero and '있음' or '없음'))
  if ready == 1 and ptr == expected_ptr and nonzero then
    emu.log('    ★ AC RECORD PASS: 레코드·표시목록·글리프를 엔진이 직접 구성했다')
  else
    emu.log('    ★ AC RECORD FAIL: 화면과 이 로그를 알려줄 것')
  end
end

local function disarm()
  for i = 0, 2 do emu.write(ENGINE_AT + i, 0, MEM) end
  armed = false
  vram_restore()
  emu.log(string.format('[%d] AC RECORD END · VRAM %d 워드 복구', frames, VRAM_WORDS))
end

emu.addEventCallback(function()
  frames = frames + 1
  if not checked and stub_ok() then
    checked = true
    emu.log('준비됨 -- 디스크 훅과 상주부 확인')
  elseif frames == 1800 and not checked then
    emu.log('★ 훅/상주부 없음: build/patch/subtitle_resident/ 디스크로 실행할 것')
  end

  if inspect_at > 0 and frames >= inspect_at then inspect_at = 0; inspect() end

  local state = emu.getState()
  local playing = state['cdrom.adpcm.playing'] == true
  if playing and not was_playing then
    local ending = (((state['cdrom.adpcm.readAddress'] or 0) +
                     (state['cdrom.adpcm.adpcmLength'] or 0)) % 0x10000)
    local sector, rate = state['cdrom.scsi.sector'], state['cdrom.adpcm.playbackRate'] or 0
    if sector == TARGET_SECTOR and ending == TARGET_END and rate == TARGET_RATE then stage() end
  elseif playing and armed then
    local elapsed, want = frames - voice_start, part_index
    for i = #parts, 1, -1 do
      if elapsed >= parts[i].start_frame then want = i; break end
    end
    if want ~= part_index then part_index = want; select_part(want) end
  elseif not playing and was_playing and armed then
    disarm()
  end
  was_playing = playing
end, emu.eventType.startFrame)

emu.log('PROBE_SUB_AC_RECORD 0.2.0 loaded')
emu.log(string.format('  AC SNSB v%d · 엔진 %d B · 대상 조각 %d개', version, #engine, #parts))
emu.log('  Lua는 조각마다 레코드 주소 3 B + ready 1 B만 전달한다')
