-- SUB 0.5.47 -- 전체 ADPCM 마스터 native LBA 관찰 (지연 polling)
--
-- 전체 런타임 음성을 탐지한다. 자막/state/selector는 건드리지 않는다.
-- 효과음은 이 스크립트에서 추정하지 않는다. 효과음 표식은 voice_keys.tsv의
-- 명시적 kind=효과음만 별도 단계에서 사용한다.

local MEM = emu.memType.pceMemory
local AC = emu.memType.pceArcadeCardRam
local APCM = emu.memType.pceAdpcmRam

local AC_SLOT = 0x1F2700
local AC_INDEX = 0x1F2800
local STRIDE = 9
local TABLE = 'C:/snatcher/build/cutscene_subs/adpcm_lba_master_index_upload.bin'
local OUT = 'C:/snatcher/dump/sub/adpcm_native_047.tsv'

local fh = io.open(TABLE, 'rb')
if not fh then
  emu.log('SUB 0.5.47 표가 없다: ' .. TABLE)
  return
end
local data = fh:read('*a')
fh:close()
if #data == 0 or #data % STRIDE ~= 0 then
  emu.log(string.format('SUB 0.5.47 표 크기 오류: %d B', #data))
  return
end

for i = 1, #data do
  emu.write(AC_INDEX + i - 1, data:byte(i), AC)
end
for i = 0, 12 do emu.write(AC_SLOT + i, 0, AC) end

local entries = #data // STRIDE
local byLba = {}
for i = 0, entries - 1 do
  local o = i * STRIDE
  local lba = (data:byte(o + 1) << 16) | (data:byte(o + 2) << 8) | data:byte(o + 3)
  byLba[lba] = data:sub(o + 4, o + 9)
end

local out = io.open(OUT, 'w')
if out then
  out:write('voice\tframe\tstatus\tlba\tnative_key\ttrue_key\tprobes\tbuild\tverdict\n')
end

local function state()
  local ok, s = pcall(emu.getState)
  if ok and type(s) == 'table' then return s end
  return nil
end

local function num(s, key)
  local v = s and s[key]
  if type(v) == 'number' then return math.floor(v) end
  return -1
end

local function hex6(k)
  return (k:gsub('.', function(c) return string.format('%02X', c:byte()) end))
end

local function trueKey(s)
  local ra = num(s, 'cdrom.adpcm.readAddress')
  local len = num(s, 'cdrom.adpcm.adpcmLength')
  local rate = num(s, 'cdrom.adpcm.playbackRate') & 0xFF
  local fin = (ra + len) & 0xFFFF
  return string.char(fin & 0xFF, (fin >> 8) & 0xFF, rate,
    emu.read(fin // 4, APCM) or 0,
    emu.read(fin // 2, APCM) or 0,
    emu.read((fin * 5) // 8, APCM) or 0)
end

local function slot()
  local t = {}
  for i = 0, 12 do t[i] = emu.read(AC_SLOT + i, AC) or 0 end
  return t
end

local voices, prev = 0, false
local pending, pendingAge, pendingState = false, 0, nil
local POLL_LIMIT = 12
local okN, badN, missN, noHookN = 0, 0, 0, 0

emu.addEventCallback(function()
  local s = state()
  if not s then return end
  local playing = s['cdrom.adpcm.playing'] == true
  if playing and not prev then
    -- playing 상승과 native hook 실행 순서는 같은 프레임에서 경합할 수 있다.
    -- 슬롯이 채워질 때까지 다음 프레임들에서 자동 polling한다.
    pending, pendingAge, pendingState = true, 0, s
    prev = true
    return
  end
  prev = playing
  if not pending then return end
  pendingAge = pendingAge + 1
  local peek = emu.read(AC_SLOT, AC) or 0
  if peek == 0 and pendingAge < POLL_LIMIT then return end
  pending = false
  local sampleState = pendingState or s
  pendingState = nil
  voices = voices + 1

  local t = slot()
  local status = t[0]
  local lba = (t[1] << 16) | (t[2] << 8) | t[3]
  local native = string.char(t[4], t[5], t[6], t[7], t[8], t[9])
  local real = trueKey(sampleState)
  local verdict
  if status == 0 then
    noHookN = noHookN + 1; verdict = 'NO-HOOK'
  elseif status == 0xA1 and native == real then
    okN = okN + 1; verdict = 'OK'
  elseif status == 0xA0 then
    missN = missN + 1; verdict = 'MISS'
  else
    badN = badN + 1; verdict = 'WRONG-KEY'
  end

  if out then
    out:write(string.format('%d\t%d\t%02X\t%06X\t%s\t%s\t%d\t%02X\t%s\n',
      voices, num(s, 'ppu.frameCount'), status, lba, hex6(native), hex6(real),
      t[11], t[12], verdict))
    out:flush()
  end
  emu.log(string.format('SUB 0.5.47 #%d ALL wait %d st $%02X lba %06X build $%02X %s',
    voices, pendingAge, status, lba, t[12], verdict))
  for i = 0, 12 do emu.write(AC_SLOT + i, 0, AC) end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if out then out:close() end
  emu.log(string.format('SUB 0.5.47 끝 -- 전체 %d · OK %d · 오답 %d · miss %d · 훅없음 %d',
    voices, okN, badN, missN, noHookN))
  emu.log('  ' .. OUT)
end, emu.eventType.scriptEnded)

emu.log(string.format('SUB 0.5.47 loaded -- 전체 ADPCM %d 항목을 AC $%06X 에 업로드', entries, AC_INDEX))
emu.log('  native 탐지만 수행 · 효과음 분류/자막 렌더링/state 변경 없음')
emu.log('  결과: ' .. OUT)
