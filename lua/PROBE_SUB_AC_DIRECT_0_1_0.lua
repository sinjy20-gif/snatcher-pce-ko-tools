-- PROBE_SUB_AC_DIRECT 0.1.0
-- 네이티브 자막 2단계 POC: 엔진이 AC $1C0000의 팩에서 글리프를 직접 읽는다.
--
-- 시험 대상은 접수처 첫 음성 하나로 고정한다.
--   sector $003078 · ADPCM 끝 $6800 · 재생률 $0E
--   "금일부로 JUNKER로 임명된"
--
-- 먼저 LOAD_SUBTITLE_PACK_AC_0_1_0.lua를 한 번 실행해야 한다.
-- build/patch/subtitle_resident/ 디스크의 $601E 훅과 $7FA0 상주부를 사용한다.
-- Lua는 음성 감지, 엔진 설치, VRAM 백업/복구만 맡는다.
-- 글리프 패턴과 표시 레코드는 Lua에서 엔진으로 복사하지 않는다.

local MEM = emu.memType.pceMemory
local AC = emu.memType.pceArcadeCardRam
local VRAM = emu.memType.pceVideoRam

local ENGINE_AT, STUB_AT = 0x5B80, 0x7FA0
local PACK_AT = 0x1C0000
local PAT_VRAM, VRAM_WORDS = 0x7900, 19 * 0x40
local TARGET_SECTOR, TARGET_END, TARGET_RATE = 0x003078, 0x6800, 0x0E
local READY_OFF, GLYPHS = 146, 16
local ENGINE_PATH = 'C:/snatcher/build/cutscene_subs/engine_ac_poc.bin'

local function slurp(path)
  local f = assert(io.open(path, 'rb'), 'cannot open ' .. path)
  local data = f:read('*a')
  f:close()
  local out = {}
  for i = 1, #data do out[i] = data:byte(i) end
  return out
end

local engine = slurp(ENGINE_PATH)
assert(#engine <= 704, string.format('engine too large: %d', #engine))

local function ac8(address)
  return emu.read(address, AC) or -1
end

assert(ac8(PACK_AT + 0) == 0x53 and ac8(PACK_AT + 1) == 0x4E and
       ac8(PACK_AT + 2) == 0x53 and ac8(PACK_AT + 3) == 0x42,
       'AC $1C0000 has no SNSB pack; run LOAD_SUBTITLE_PACK_AC_0_1_0.lua first')
local pack_version = ac8(PACK_AT + 4) | (ac8(PACK_AT + 5) << 8)
assert(pack_version == 5, string.format('AC pack version is %d, expected 5', pack_version))

local frames, was_playing = 0, false
local armed, checked = false, false
local backup = nil
local inspect_at = 0

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
  for i = 0, VRAM_WORDS - 1 do
    emu.write(PAT_VRAM + i, backup[i], VRAM)
  end
  backup = nil
end

local function stage()
  vram_save()
  for i = 1, #engine do
    emu.write(ENGINE_AT + i - 1, engine[i], MEM)
  end
  armed = true
  inspect_at = frames + 8
  emu.log(string.format('[%d] AC DIRECT START sector %06X 끝 %04X 률 %02X',
                        frames, TARGET_SECTOR, TARGET_END, TARGET_RATE))
  emu.log(string.format('  Lua -> 엔진 %d B만 설치 · 글리프/레코드 복사 0 B', #engine))
end

local function disarm()
  for i = 0, 2 do emu.write(ENGINE_AT + i, 0, MEM) end
  armed = false
  vram_restore()
  emu.log(string.format('[%d] AC DIRECT END · VRAM %d 워드 복구', frames, VRAM_WORDS))
end

local function inspect()
  local ready = emu.read(ENGINE_AT + READY_OFF, MEM) or 0
  local nonzero = false
  for i = 0, 63 do
    if (emu.read(PAT_VRAM + i, VRAM) or 0) ~= 0 then nonzero = true; break end
  end
  emu.log(string.format('  검사: ready=%d · VRAM 패턴=%s', ready,
                        nonzero and '있음' or '없음'))
  if ready == 1 and nonzero then
    emu.log('  ★ AC DIRECT PASS: 엔진이 AC 팩에서 글리프를 직접 읽었다')
  else
    emu.log('  ★ AC DIRECT FAIL: 화면과 위 값을 알려줄 것')
  end
end

emu.addEventCallback(function()
  frames = frames + 1

  if not checked and stub_ok() then
    checked = true
    emu.log('준비됨 -- 디스크 훅과 상주부 확인')
  elseif frames == 1800 and not checked then
    emu.log('★ 훅/상주부 없음: build/patch/subtitle_resident/ 디스크로 실행할 것')
  end

  if inspect_at > 0 and frames >= inspect_at then
    inspect_at = 0
    inspect()
  end

  local state = emu.getState()
  local playing = state['cdrom.adpcm.playing'] == true
  if playing and not was_playing then
    local ending = (((state['cdrom.adpcm.readAddress'] or 0) +
                     (state['cdrom.adpcm.adpcmLength'] or 0)) % 0x10000)
    local sector = state['cdrom.scsi.sector']
    local rate = state['cdrom.adpcm.playbackRate'] or 0
    if sector == TARGET_SECTOR and ending == TARGET_END and rate == TARGET_RATE then
      stage()
    end
  elseif not playing and was_playing and armed then
    disarm()
  end
  was_playing = playing
end, emu.eventType.startFrame)

emu.log('PROBE_SUB_AC_DIRECT 0.1.0 loaded')
emu.log(string.format('  AC SNSB v%d 확인 · 엔진 %d B · 고정 글리프 %d자',
                      pack_version, #engine, GLYPHS))
emu.log('  접수처 첫 음성에서 엔진이 AC 팩을 직접 읽는지 검증한다')
