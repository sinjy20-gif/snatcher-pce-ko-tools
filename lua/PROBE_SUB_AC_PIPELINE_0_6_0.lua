-- PROBE_SUB_AC_PIPELINE 0.6.0
-- 네이티브 자막 수명주기 통합 POC:
--   VRAM -> AC 저장(helper) -> AC 팩 조회/자체 시간 전환(renderer)
--   -> AC -> VRAM 복원(helper) -> 게임 UI 복귀
-- 성공 경로에서 Lua는 글리프/레코드/조각/VRAM을 옮기지 않는다.

local MEM, AC, VRAM = emu.memType.pceMemory, emu.memType.pceArcadeCardRam,
                       emu.memType.pceVideoRam
local ENGINE_AT, STUB_AT, PACK_AT = 0x5B80, 0x7FA0, 0x1C0000
local BACKUP_AT = 0x1F0400
local TAIL_LO, TAIL_HI = 0x5E20, 0x5E3F
local VRAM_BYTE_AT, VRAM_BYTES = 0x7900 * 2, 19 * 0x40 * 2
local KEY = { 0x78, 0x30, 0x00, 0x00, 0x68, 0x0E }

local HELPER_PATH = 'C:/snatcher/build/cutscene_subs/subtitle_vram_helper.bin'
local ENGINE_PATH = 'C:/snatcher/build/cutscene_subs/engine_ac_timed_safe_poc.bin'
local PACK_PATH = 'C:/snatcher/build/cutscene_subs/subtitle_pack.bin'

-- subtitle_vram_helper.json
local H_COMMAND, H_STATUS = 145, 146
-- engine_ac_timed_safe_poc.json
local E_READY, E_COUNT, E_SELECTOR, E_ELAPSED, E_RECORD = 364, 365, 366, 455, 461

local function slurp(path)
  local f = assert(io.open(path, 'rb'), 'cannot open ' .. path)
  local d = f:read('*a'); f:close()
  local t = {}; for i = 1, #d do t[i] = d:byte(i) end
  return t
end
local helper, engine, pack = slurp(HELPER_PATH), slurp(ENGINE_PATH), slurp(PACK_PATH)
assert(#helper <= 672 and #engine <= 672, 'engine crossed safe RAM limit $5E20')

local function p8(o) return pack[o + 1] end
local function p16(o) return p8(o) | (p8(o + 1) << 8) end
local function p32(o) return p16(o) | (p16(o + 2) << 16) end
for i = 0, 5 do
  assert((emu.read(PACK_AT + i, AC) or -1) == p8(i),
         'AC pack differs; run LOAD_SUBTITLE_PACK_AC_0_1_0.lua again')
end

local P = { count=p16(14), index=p32(16), records=p32(26), chars=p32(38),
            stride=p8(42), cell=p8(35) }
local expected = {}
for i = 0, P.count - 1 do
  local at, same = P.index + i * P.stride, true
  for k = 0, 5 do if p8(at + k) ~= KEY[k + 1] then same = false; break end end
  if same then expected[#expected + 1] = {frame=p16(at + 7), rec=p32(at + 9)} end
end
assert(#expected == 2 and expected[1].frame == 0 and expected[2].frame == 120,
       'target pack entries changed')

local function text_at(rec)
  local at, out = P.records + rec, ''
  for i = 0, p8(at) - 1 do
    local cell = at + 6 + i * P.cell
    out = out .. utf8.char(p16(P.chars + p16(cell) * 2))
  end
  return out
end
local function loaded_text()
  local n, out = emu.read(ENGINE_AT + E_COUNT, MEM) or 0, ''
  for i = 0, n - 1 do
    local at = ENGINE_AT + E_RECORD + 6 + i * 4
    local id = (emu.read(at, MEM) or 0) | ((emu.read(at + 1, MEM) or 0) << 8)
    out = out .. utf8.char(p16(P.chars + id * 2))
  end
  return out
end

local function install(image)
  for i = 1, #image do emu.write(ENGINE_AT + i - 1, image[i], MEM) end
end
local function zero_magic()
  for i = 0, 2 do emu.write(ENGINE_AT + i, 0, MEM) end
end
local function stub_ok()
  return emu.read(STUB_AT, MEM) == 0x08 and emu.read(0x601E, MEM) == 0x20
end

local frames, was_playing, checked = 0, false, false
local phase, original_vram, original_tail = 'idle', nil, nil
local inspect1, inspect2 = 0, 0

local function take_guards()
  original_vram = {}
  for i = 0, VRAM_BYTES - 1 do original_vram[i] = emu.read(VRAM_BYTE_AT + i, VRAM) or 0 end
  original_tail = {}
  for a = TAIL_LO, TAIL_HI do original_tail[a] = emu.read(a, MEM) or 0 end
end
local function tail_diff()
  local bad = 0
  for a = TAIL_LO, TAIL_HI do
    if (emu.read(a, MEM) or 0) ~= original_tail[a] then bad = bad + 1 end
  end
  return bad
end
local function ac_backup_diff()
  local bad = 0
  for i = 0, VRAM_BYTES - 1 do
    if (emu.read(BACKUP_AT + i, AC) or 0) ~= original_vram[i] then bad = bad + 1 end
  end
  return bad
end
local function vram_diff()
  local bad = 0
  for i = 0, VRAM_BYTES - 1 do
    if (emu.read(VRAM_BYTE_AT + i, VRAM) or 0) ~= original_vram[i] then bad = bad + 1 end
  end
  return bad
end

local function begin_save()
  take_guards()
  install(helper)
  emu.write(ENGINE_AT + H_COMMAND, 0, MEM)
  emu.write(ENGINE_AT + H_STATUS, 0, MEM)
  phase = 'saving'
  emu.log(string.format('[%d] PIPE START · VRAM 저장 helper %d B 설치', frames, #helper))
  emu.log('  성공 경로 Lua VRAM 쓰기 0 B · 다음 $601E에서 엔진이 AC로 저장')
end

local function begin_renderer()
  local bad = ac_backup_diff()
  emu.log(string.format('  저장검사: status=1 · AC 백업 불일치 %d/%d bytes', bad, VRAM_BYTES))
  if bad ~= 0 then
    zero_magic(); phase = 'failed'
    emu.log('  ★ PIPE SAVE FAIL: 자막 엔진을 시작하지 않았다')
    return
  end
  emu.log('  ★ PIPE SAVE PASS: VDC $7900 -> AC $1F0400 byte exact')
  install(engine)
  for i = 1, 6 do emu.write(ENGINE_AT + E_SELECTOR + i - 1, KEY[i], MEM) end
  inspect1, inspect2 = frames + 8, frames + 128
  phase = 'rendering'
  emu.log(string.format('  렌더러 %d B 설치 · 음성 키 6 B 한 번 · 이후 조각 제어 0 B', #engine))
end

local function inspect(part)
  local actual, wanted = loaded_text(), text_at(expected[part].rec)
  local ready = emu.read(ENGINE_AT + E_READY, MEM) or 0
  local elapsed = emu.read(ENGINE_AT + E_ELAPSED, MEM) or 0
  local bad = tail_diff()
  emu.log(string.format('  자체검사 %d/2 · elapsed=%d · ready=%d · tail diff=%d/32 · "%s"',
                        part, elapsed, ready, bad, actual))
  if ready == 1 and actual == wanted and bad == 0 then
    emu.log('  ★ PIPE TIMED PASS: AC 조회와 자체 시각 전환 정상')
  else
    emu.log(string.format('  ★ PIPE TIMED FAIL: 기대="%s"', wanted))
  end
end

local function begin_restore()
  install(helper)
  emu.write(ENGINE_AT + H_COMMAND, 1, MEM)
  emu.write(ENGINE_AT + H_STATUS, 0, MEM)
  phase = 'restoring'
  emu.log(string.format('[%d] 음성 끝 · 복원 helper 설치 · 다음 $601E에서 AC -> VRAM', frames))
end

local function finish_restore()
  local bad, tail = vram_diff(), tail_diff()
  emu.log(string.format('  복원검사: status=2 · VRAM 불일치 %d/%d bytes', bad, VRAM_BYTES))
  if bad == 0 then emu.log('  ★ PIPE RESTORE PASS: AC $1F0400 -> VDC $7900 byte exact') end
  emu.log(string.format('  RAM TAIL: diff=%d/32', tail))
  if bad == 0 and tail == 0 then
    emu.log('  ★ PIPELINE 0.6.0 PASS: 저장 · 자체 자막 · 복원 완료 -- UI 복귀 확인')
  else
    emu.log('  ★ PIPELINE FAIL: 위 불일치를 확인할 것')
  end
  phase, original_vram, original_tail = 'idle', nil, nil
end

emu.addEventCallback(function()
  frames = frames + 1
  if not checked and stub_ok() then checked = true; emu.log('준비됨 -- 디스크 훅과 상주부 확인') end

  -- helper는 이전 프레임의 $601E에서 실행되고 스스로 magic을 지운다.
  if phase == 'saving' and (emu.read(ENGINE_AT + H_STATUS, MEM) or 0) == 1 then
    begin_renderer()
  elseif phase == 'restoring' and (emu.read(ENGINE_AT + H_STATUS, MEM) or 0) == 2 then
    finish_restore()
  end
  if phase == 'rendering' and inspect1 > 0 and frames >= inspect1 then inspect1 = 0; inspect(1) end
  if phase == 'rendering' and inspect2 > 0 and frames >= inspect2 then inspect2 = 0; inspect(2) end

  local s = emu.getState() or {}
  local playing = s['cdrom.adpcm.playing'] == true
  if playing and not was_playing and phase == 'idle' then
    local ending = (((s['cdrom.adpcm.readAddress'] or 0) +
                     (s['cdrom.adpcm.adpcmLength'] or 0)) % 0x10000)
    if s['cdrom.scsi.sector'] == 0x003078 and ending == 0x6800 and
       (s['cdrom.adpcm.playbackRate'] or 0) == 0x0E then begin_save() end
  elseif not playing and was_playing and phase == 'rendering' then
    begin_restore()
  end
  was_playing = playing
end, emu.eventType.startFrame)

emu.log('PROBE_SUB_AC_PIPELINE 0.6.0 loaded')
emu.log(string.format('  helper %d B · renderer %d B · 둘 다 $5E20 안전선 이내', #helper, #engine))
emu.log('  VRAM 저장/복원과 2조각 자체 전환을 한 번에 검증한다')
emu.log('  ★ 먼저 LOAD_SUBTITLE_PACK_AC_0_1_0.lua를 실행해 둘 것')
