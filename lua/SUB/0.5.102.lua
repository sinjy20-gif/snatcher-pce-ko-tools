-- SUB 0.5.102 -- 오프닝 CD-DA 자막 중간 스킵을 실제 게임 분기에서 종료
--
-- 기준선:
--   BIOS 0.4.6.48 + 0.5.77 은 CD-DA 정상 종료 화면이 정상이다.
--
-- 0.5.101 실측:
--   $8011 LDA $222D
--   $8014 AND #$0C
--   $8016 BEQ $801B
--   $8018 JMP $8411
--
-- 따라서 오디오 정지나 프레임을 추측하지 않고, 실제 오프닝 스킵 목적지
-- $8411에 들어온 순간 CD-DA 자막이 active(state 2)일 때만 state 3을 요청한다.
-- 복원 경로와 sprite wipe는 네이티브 엔진이 그대로 수행하며, 복원 직전 백업
-- refresh는 정상 종료가 검증된 0.5.77을 그대로 사용한다.

local VERSION = '0.5.102'
local TAG = 'SUB ' .. VERSION
local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

-- 정상 CD-DA 종료에서 검증된 backup refresh 동작.
dofile('C:/snatcher/lua/SUB/0.5.77-refresh-cdda-backup.lua')

local OPENING_SKIP = 0x8411
local TRACK = 0x26F9
local STATE = 0x7FDF
local SIG = 0x5DDA
local ELAPSED = 0x5E1D

local CDDA_TRACK = 0x11
local CDDA_SIG = 0x38

local frame = 0
local hits, armed, rejected = 0, 0, 0

local function rb(at)
  return emu.read(at, MEM) or 0
end

local function elapsed()
  return rb(ELAPSED) | (rb(ELAPSED + 1) << 8)
end

emu.addEventCallback(function()
  frame = frame + 1
end, emu.eventType.endFrame)

emu.addMemoryCallback(function()
  hits = hits + 1

  local track = rb(TRACK) & 0x7F
  local state = rb(STATE)
  local sig = rb(SIG)
  local time = elapsed()

  -- 자막 시작 전/종료 후 스킵과 ADPCM에는 개입하지 않는다.
  if track ~= CDDA_TRACK or state ~= 0x02 or sig ~= CDDA_SIG then
    rejected = rejected + 1
    emu.log(string.format(
      '%s · OPENING SKIP PASS f%d · track=$%02X state=$%02X sig=$%02X elapsed=%d',
      TAG, frame, track, state, sig, time))
    return
  end

  emu.write(STATE, 0x03, MEM)
  armed = armed + 1
  emu.log(string.format(
    '%s ★ OPENING MID-SKIP f%d · track=$%02X state $02->$03 · elapsed=%d',
    TAG, frame, track, time))
end, emu.callbackType.exec, OPENING_SKIP, OPENING_SKIP, CPU, MEM)

emu.addEventCallback(function()
  emu.log(string.format('%s 끝 -- skip hit %d · 종료 요청 %d · 무개입 %d',
    TAG, hits, armed, rejected))
end, emu.eventType.scriptEnded)

emu.log(TAG .. ' loaded -- BIOS 0.4.6.48 opening CD-DA exact skip fix')
emu.log('  정상 종료: 0.5.77 유지 · 중간 스킵: $8411에서 즉시 state 3')
emu.log('  자막 전/종료 후 스킵 및 ADPCM 무개입 · 키 입력 없음')
