-- CDDA_NATIVE_TRACE 0.1.0 -- 0.4.6.23 Track 17 native POC read-only trace
--
-- 0.4.6.23-cdda17-native에서 자막이 나오지 않을 때 실행 사슬을 한 번에 가른다.
-- 게임 RAM/VRAM/코드에는 쓰지 않는다. exec/write callback과 RAM 읽기만 한다.
--
-- 감시 사슬:
--   $600C -> $601E -> $7F49 -> $FEC4 -> $5B83 -> $5B91 -> $5C86 -> $5DDA
--
-- 사용:
--   1) 0.4.6.23 후보 BIOS+CUE를 그대로 실행한다.
--   2) 이 Lua 하나만 켠다.
--   3) 오프닝 Track 17을 처음부터 46초까지 재생한다.
--
-- 결과: dump/cdda_native_trace_0_1_0_<시각>.tsv

local VERSION = '0.1.0'
local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce
local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH = 'C:/snatcher/dump/cdda_native_trace_0_1_0_' .. STAMP .. '.tsv'

local TRACK = 0x26F9
local ACCEPTED = 0x263C
local PLAYING = 0x2638
local STATE = 0x7FDF

local WATCH = {
  { name='arm600c', addr=0x600C },
  { name='hook601e', addr=0x601E },
  { name='resident', addr=0x7F49 },
  { name='gate', addr=0xFEC4 },
  { name='entry', addr=0x5B83 },
  { name='rebuild', addr=0x5B91 },
  { name='push', addr=0x5C86 },
  { name='timer', addr=0x5DDA },
}

local function rb(a)
  return emu.read(a, MEM) or 0
end

local function hx(a, n)
  local t = {}
  for i=0,n-1 do t[#t+1] = string.format('%02X', rb(a+i)) end
  return table.concat(t, '')
end

for _, item in ipairs(WATCH) do
  local w = item
  w.frame, w.total = 0, 0
  emu.addMemoryCallback(function()
    w.frame = w.frame + 1
    w.total = w.total + 1
  end, emu.callbackType.exec, w.addr, w.addr, CPU, MEM)
end

local stateWrites, stateWritesTotal = 0, 0
emu.addMemoryCallback(function()
  stateWrites = stateWrites + 1
  stateWritesTotal = stateWritesTotal + 1
end, emu.callbackType.write, STATE, STATE, CPU, MEM)

local out = assert(io.open(PATH, 'w'))
local head = {'frame','sector','track','accepted','playing','state','state_w'}
for _, w in ipairs(WATCH) do head[#head+1] = w.name end
head[#head+1] = 'engine_sig'
out:write(table.concat(head, '\t') .. '\n')
out:flush()

local frame = 0
local lastTrack, lastAccepted, lastPlaying, lastState = -1, -1, -1, -1
local sectorKey = nil

local function sector()
  local ok, s = pcall(emu.getState)
  if not ok or not s then return -1 end
  if sectorKey == nil then
    for _, k in ipairs({'cdrom.audioPlayer.currentSector',
                        'cdrom.audio.currentSector',
                        'cdrom.currentSector'}) do
      if s[k] ~= nil then sectorKey = k; break end
    end
  end
  local v = sectorKey and s[sectorKey] or nil
  return type(v) == 'number' and math.floor(v) or -1
end

local function totals()
  local t = {}
  for _, w in ipairs(WATCH) do t[#t+1] = w.name .. '=' .. w.total end
  return table.concat(t, ' ')
end

emu.addEventCallback(function()
  frame = frame + 1
  local tr, ac, pl, st = rb(TRACK), rb(ACCEPTED), rb(PLAYING), rb(STATE)
  local changed = tr ~= lastTrack or ac ~= lastAccepted or
                  pl ~= lastPlaying or st ~= lastState
  local active = (tr == 0x10) or st ~= 0 or changed

  if active or frame % 60 == 0 then
    local row = {frame, sector(), string.format('%02X',tr),
                 string.format('%02X',ac), string.format('%02X',pl),
                 string.format('%02X',st), stateWrites}
    for _, w in ipairs(WATCH) do row[#row+1] = w.frame end
    row[#row+1] = hx(0x5B80,3)
    out:write(table.concat(row, '\t') .. '\n')
    out:flush()
  end

  emu.drawString(4, 4,
    string.format('CDDA native T=%02X A=%02X P=%02X S=%02X',tr,ac,pl,st),
    0xFFFFFF, 0x000000)
  emu.drawString(4, 14,
    string.format('R/G/E/B/P/T %d/%d/%d/%d/%d/%d',
      WATCH[3].frame,WATCH[4].frame,WATCH[5].frame,
      WATCH[6].frame,WATCH[7].frame,WATCH[8].frame),
    0xFFFFFF, 0x000000)

  if changed then
    emu.log(string.format(
      'CDDA native #%d track=%02X accepted=%02X playing=%02X state=%02X · %s',
      frame,tr,ac,pl,st,totals()))
  end
  lastTrack, lastAccepted, lastPlaying, lastState = tr, ac, pl, st
  for _, w in ipairs(WATCH) do w.frame = 0 end
  stateWrites = 0
end, emu.eventType.startFrame)

emu.addEventCallback(function()
  out:flush(); out:close()
  emu.log('CDDA_NATIVE_TRACE 종료 · ' .. totals() ..
          ' state_w=' .. stateWritesTotal .. ' · ' .. PATH)
end, emu.eventType.scriptEnded)

emu.log('CDDA_NATIVE_TRACE ' .. VERSION .. ' loaded -- READ ONLY')
emu.log('  BIOS $FEC4: ' .. hx(0xFEC4,12))
emu.log('  resident $7F49: ' .. hx(0x7F49,12))
emu.log('  engine $5B80: ' .. hx(0x5B80,12))
emu.log('  0.4.6.23 후보에서 오프닝 Track 17을 46초까지 재생하세요.')
emu.log('  log: ' .. PATH)
