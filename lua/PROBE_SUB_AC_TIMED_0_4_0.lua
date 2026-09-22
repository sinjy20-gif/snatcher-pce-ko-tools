-- PROBE_SUB_AC_TIMED 0.4.0
-- 시작 때 음성 키 6 B를 한 번만 전달한다. 조각 전환은 엔진의 자체 프레임 카운터가 한다.
--
-- ★ 사용 중지 (2026-08-24 실측)
-- 두 조각 표시와 로그상 VRAM 복구는 통과했지만 음성 종료 뒤 실제 게임 UI가
-- 돌아오지 않았다. 마지막 정상 기준은 PROBE_SUB_AC_LOOKUP_0_3_0.lua다.
-- 원인 분리 전에는 이 파일과 이를 바탕으로 한 후속 생명주기 POC를 실행하지 않는다.

local MEM, AC = emu.memType.pceMemory, emu.memType.pceArcadeCardRam
local VRAM = emu.memType.pceVideoRam
local ENGINE_AT, STUB_AT, PACK_AT = 0x5B80, 0x7FA0, 0x1C0000
local PAT_VRAM, VRAM_WORDS = 0x7900, 19 * 0x40
local KEY = { 0x78, 0x30, 0x00, 0x00, 0x68, 0x0E } -- sector 003078 · end 6800 · rate 0E
-- engine_ac_timed_poc.json 생성 오프셋
local OFF_READY, OFF_COUNT, OFF_SELECTOR, OFF_ELAPSED, OFF_RECORD = 395, 396, 397, 486, 492
local ENGINE_PATH = 'C:/snatcher/build/cutscene_subs/engine_ac_timed_poc.bin'
local PACK_PATH = 'C:/snatcher/build/cutscene_subs/subtitle_pack.bin'

local function slurp(path)
  local f = assert(io.open(path, 'rb'), 'cannot open ' .. path)
  local d = f:read('*a'); f:close()
  local t = {}; for i = 1, #d do t[i] = d:byte(i) end
  return t
end
local engine, pack = slurp(ENGINE_PATH), slurp(PACK_PATH)
local function u8(o) return pack[o + 1] end
local function u16(o) return u8(o) | (u8(o + 1) << 8) end
local function u32(o) return u16(o) | (u16(o + 2) << 16) end
assert(#engine <= 704 and u8(0) == 0x53 and u8(1) == 0x4E and
       u8(2) == 0x53 and u8(3) == 0x42 and u16(4) == 5, 'invalid engine or pack')
for i = 0, 5 do
  assert((emu.read(PACK_AT + i, AC) or -1) == u8(i),
         'AC pack differs; run LOAD_SUBTITLE_PACK_AC_0_1_0.lua again')
end

local P = { count = u16(14), index = u32(16), records = u32(26),
            chars = u32(38), stride = u8(42), cell = u8(35) }
local expected = {}
for i = 0, P.count - 1 do
  local at = P.index + i * P.stride
  local same = true
  for k = 0, 5 do if u8(at + k) ~= KEY[k + 1] then same = false; break end end
  if same then expected[#expected + 1] = { frame = u16(at + 7), rec = u32(at + 9) } end
end
assert(#expected == 2 and expected[2].frame == 120, 'timed POC pack entries changed; rebuild engine')

local function pack_text(rec)
  local at, text = P.records + rec, ''
  for i = 0, u8(at) - 1 do
    local cell = at + 6 + i * P.cell
    text = text .. utf8.char(u16(P.chars + u16(cell) * 2))
  end
  return text
end
local function loaded_text()
  local count, text = emu.read(ENGINE_AT + OFF_COUNT, MEM) or 0, ''
  for i = 0, count - 1 do
    local at = ENGINE_AT + OFF_RECORD + 6 + i * 4
    local id = (emu.read(at, MEM) or 0) | ((emu.read(at + 1, MEM) or 0) << 8)
    text = text .. utf8.char(u16(P.chars + id * 2))
  end
  return text
end

local frames, was_playing, armed, checked = 0, false, false, false
local voice_start, inspect_first, inspect_second = 0, 0, 0
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

local function stage()
  vram_save()
  for i = 1, #engine do emu.write(ENGINE_AT + i - 1, engine[i], MEM) end
  for i = 1, 6 do emu.write(ENGINE_AT + OFF_SELECTOR + i - 1, KEY[i], MEM) end
  armed, voice_start = true, frames
  inspect_first, inspect_second = frames + 8, frames + 128
  emu.log(string.format('[%d] AC TIMED START · 엔진 %d B + 음성 키 6 B', frames, #engine))
  emu.log('  ★ 이 뒤 음성 종료까지 Lua의 조각 제어 쓰기 0 B')
end

local function inspect(part)
  local actual, wanted = loaded_text(), pack_text(expected[part].rec)
  local ready = emu.read(ENGINE_AT + OFF_READY, MEM) or 0
  local elapsed = emu.read(ENGINE_AT + OFF_ELAPSED, MEM) or 0
  emu.log(string.format('  자체검사 %d/2 · engine_elapsed=%d · ready=%d · 찾은 글="%s"',
                        part, elapsed, ready, actual))
  if ready == 1 and actual == wanted then
    emu.log('  ★ AC TIMED PASS: 엔진이 자체 시각으로 올바른 조각을 선택했다')
  else
    emu.log(string.format('  ★ AC TIMED FAIL: 기대="%s"', wanted))
  end
end

local function disarm()
  for i = 0, 2 do emu.write(ENGINE_AT + i, 0, MEM) end
  armed = false; vram_restore()
  emu.log(string.format('[%d] AC TIMED END · 재생 중 조각 제어 0 B · VRAM 복구', frames))
end

emu.addEventCallback(function()
  frames = frames + 1
  if not checked and stub_ok() then checked = true; emu.log('준비됨 -- 디스크 훅과 상주부 확인')
  elseif frames == 1800 and not checked then emu.log('★ subtitle_resident 디스크 훅이 없다') end
  if inspect_first > 0 and frames >= inspect_first then inspect_first = 0; inspect(1) end
  if inspect_second > 0 and frames >= inspect_second then inspect_second = 0; inspect(2) end

  local s = emu.getState() or {}
  local playing = s['cdrom.adpcm.playing'] == true
  if playing and not was_playing then
    local ending = (((s['cdrom.adpcm.readAddress'] or 0) +
                     (s['cdrom.adpcm.adpcmLength'] or 0)) % 0x10000)
    if s['cdrom.scsi.sector'] == 0x003078 and ending == 0x6800 and
       (s['cdrom.adpcm.playbackRate'] or 0) == 0x0E then stage() end
  elseif not playing and was_playing and armed then disarm() end
  was_playing = playing
end, emu.eventType.startFrame)

emu.log('PROBE_SUB_AC_TIMED 0.4.0 loaded')
emu.log(string.format('  AC SNSB v5 · 엔진 %d B · 키 6 B 한 번 · 자체 전환 120f', #engine))
emu.log('  재생 중 Lua는 조각 선택이나 레코드 주소를 쓰지 않는다')
