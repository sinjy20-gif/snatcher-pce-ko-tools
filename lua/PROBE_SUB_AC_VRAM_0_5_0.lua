-- PROBE_SUB_AC_VRAM 0.5.0
-- 엔진이 VRAM 1216워드를 AC $1F0400에 저장하고 음성 종료 뒤 직접 복원한다.
-- Lua의 snapshot은 검증 및 실패 시 비상 복구 전용이다.
-- r1: 교대 TIA/TAI 왕복을 폐기. TIN 고정포트 저장 + LDA $1A00 수동 복원.
-- r2: VDC 포트 byte order와 pceVideoRam word order를 native/swapped 양쪽으로 검사.
-- r3: Mesen pceVideoRam은 바이트 주소다. VDC word $7900 -> mem byte $F200으로 수정.
-- ★ 2026-08-24 실측 통과: AC 백업 0/2432 · 엔진 복원 0/2432.
-- 0.4.0 실패 원인은 $5E20-$5E3F 침범으로 확정·수정됐다. 이 엔진은 545 B로
-- $5B80-$5DA0만 사용하므로 해당 금지 구간에 닿지 않는다.

local MEM, AC = emu.memType.pceMemory, emu.memType.pceArcadeCardRam
local VRAM = emu.memType.pceVideoRam
local ENGINE_AT, STUB_AT, PACK_AT = 0x5B80, 0x7FA0, 0x1C0000
local PAT_VRAM_WORD, VRAM_WORDS, AC_BACKUP = 0x7900, 19 * 0x40, 0x1F0400
local PAT_VRAM_BYTE, VRAM_BYTES = PAT_VRAM_WORD * 2, VRAM_WORDS * 2
local OFF_READY, OFF_COMMAND, OFF_SAVED, OFF_RESTORED = 294, 295, 296, 297
local ENGINE_PATH = 'C:/snatcher/build/cutscene_subs/engine_ac_vram_poc.bin'

local function slurp(path)
  local f = assert(io.open(path, 'rb'), 'cannot open ' .. path)
  local d = f:read('*a'); f:close()
  local t = {}; for i = 1, #d do t[i] = d:byte(i) end
  return t
end
local engine = slurp(ENGINE_PATH)
assert(#engine <= 704, 'VRAM lifecycle engine is too large')
assert((emu.read(PACK_AT, AC) or -1) == 0x53 and (emu.read(PACK_AT + 1, AC) or -1) == 0x4E,
       'AC pack missing; run LOAD_SUBTITLE_PACK_AC_0_1_0.lua first')

local frames, was_playing, armed, checked = 0, false, false, false
local inspect_save, inspect_restore = 0, 0
local snapshot = nil

local function stub_ok()
  return emu.read(STUB_AT, MEM) == 0x08 and emu.read(0x601E, MEM) == 0x20
end
local function take_snapshot()
  snapshot = {}
  for i = 0, VRAM_BYTES - 1 do snapshot[i] = emu.read(PAT_VRAM_BYTE + i, VRAM) or 0 end
end
local function backup_diff()
  local bad = 0
  for i = 0, VRAM_BYTES - 1 do
    if (emu.read(AC_BACKUP + i, AC) or 0) ~= snapshot[i] then bad = bad + 1 end
  end
  return bad
end
local function vram_diff()
  local bad = 0
  for i = 0, VRAM_BYTES - 1 do
    if (emu.read(PAT_VRAM_BYTE + i, VRAM) or 0) ~= snapshot[i] then bad = bad + 1 end
  end
  return bad
end
local function emergency_restore()
  for i = 0, VRAM_BYTES - 1 do emu.write(PAT_VRAM_BYTE + i, snapshot[i], VRAM) end
  for i = 0, 2 do emu.write(ENGINE_AT + i, 0, MEM) end
end

local function stage()
  take_snapshot()                              -- 읽기만 한다
  for i = 1, #engine do emu.write(ENGINE_AT + i - 1, engine[i], MEM) end
  armed, inspect_save = true, frames + 8
  emu.log(string.format('[%d] AC VRAM START · 엔진 %d B 설치 · Lua VRAM 쓰기 0', frames, #engine))
end

local function check_save()
  local bad = backup_diff()
  local saved, ready = emu.read(ENGINE_AT + OFF_SAVED, MEM) or 0,
                       emu.read(ENGINE_AT + OFF_READY, MEM) or 0
  emu.log(string.format('  저장검사: saved=%d · ready=%d · AC 백업 불일치 %d/%d bytes',
                        saved, ready, bad, VRAM_BYTES))
  if saved == 1 and ready == 1 and bad == 0 then
    emu.log('  ★ AC VRAM SAVE PASS: VDC $7900 -> AC $1F0400 byte exact')
  else
    emu.log('  ★ AC VRAM SAVE FAIL: 종료 때 Lua 비상 복구를 사용한다')
  end
end

local function request_restore()
  emu.write(ENGINE_AT + OFF_COMMAND, 2, MEM)    -- VRAM에는 쓰지 않는다
  inspect_restore = frames + 1
  emu.log(string.format('[%d] 복원 명령 1 B · 다음 $601E에서 엔진이 복원', frames))
end

local function check_restore()
  local bad = vram_diff()
  local restored = emu.read(ENGINE_AT + OFF_RESTORED, MEM) or 0
  local magic = emu.read(ENGINE_AT, MEM) or 0
  emu.log(string.format('  복원검사: restored=%d · magic=%02X · VRAM 불일치 %d/%d bytes',
                        restored, magic, bad, VRAM_BYTES))
  if bad == 0 and magic ~= 0x53 then
    emu.log('  ★ AC VRAM RESTORE PASS: 엔진 복원 완료 · Lua VRAM 쓰기 0')
  else
    emergency_restore()
    emu.log('  ★ AC VRAM RESTORE FAIL: 게임 보호를 위해 Lua가 비상 복구함')
  end
  armed, snapshot = false, nil
end

emu.addEventCallback(function()
  frames = frames + 1
  if not checked and stub_ok() then checked = true; emu.log('준비됨 -- 디스크 훅과 상주부 확인')
  elseif frames == 1800 and not checked then emu.log('★ subtitle_resident 디스크 훅이 없다') end
  if inspect_save > 0 and frames >= inspect_save then inspect_save = 0; check_save() end
  if inspect_restore > 0 and frames >= inspect_restore then inspect_restore = 0; check_restore() end

  local s = emu.getState() or {}
  local playing = s['cdrom.adpcm.playing'] == true
  if playing and not was_playing then
    local ending = (((s['cdrom.adpcm.readAddress'] or 0) +
                     (s['cdrom.adpcm.adpcmLength'] or 0)) % 0x10000)
    if s['cdrom.scsi.sector'] == 0x003078 and ending == 0x6800 and
       (s['cdrom.adpcm.playbackRate'] or 0) == 0x0E then stage() end
  elseif not playing and was_playing and armed then request_restore() end
  was_playing = playing
end, emu.eventType.startFrame)

emu.log('PROBE_SUB_AC_VRAM 0.5.0-r3 loaded')
emu.log(string.format('  엔진 %d B · VRAM %d워드 <-> AC $%06X', #engine, VRAM_WORDS, AC_BACKUP))
emu.log(string.format('  VDC word $%04X = Mesen byte $%04X · %d bytes 정확 비교',
                      PAT_VRAM_WORD, PAT_VRAM_BYTE, VRAM_BYTES))
