-- Subtitle temporal-borrow shadow POC 0.1.0
-- Registered ADPCM only: mirror $5B80-$5FFF to AC $1C0000, then prove that
-- the game neither writes nor executes the borrowed range until playback ends.

local EVENTS = "C:/snatcher/snatcher_tool/translation/voice_events.tsv"
local SUBS   = "C:/snatcher/snatcher_tool/translation/voice_subtitles.tsv"
local OUT    = "C:/snatcher/dump/probe_subtitle_borrow_shadow_0_1_0.tsv"
local LO, HI, SIZE = 0x5B80, 0x5FFF, 0x480
local AC_BASE = 0x1C0000
local PRELOADER = 0x5E40
local mem = emu.memType.pceMemory
local cpu = emu.memType.cpu
local ac = emu.memType.pceArcadeCardRam

local function readTsv(path)
  local f = assert(io.open(path, "rb"), "cannot open " .. path)
  local text = f:read("a"); f:close(); text = text:gsub("^\239\187\191", "")
  local header, rows = nil, {}
  for line in text:gmatch("[^\r\n]+") do
    local fields = {}
    for field in (line .. "\t"):gmatch("([^\t]*)\t") do fields[#fields + 1] = field end
    if not header then
      header = {}; for i, name in ipairs(fields) do header[name] = i end
    else rows[#rows + 1] = fields end
  end
  return header, rows
end

local function get(h, r, name) return r[h[name]] or "" end
local function endKey(fp)
  local read, len, rate = fp:match("^ADPCM_(%x+)_(%x+)_(%x+)$")
  if not read then return nil end
  local finish = (tonumber(read, 16) + tonumber(len, 16)) % 0x10000
  return finish == 0xFFFF and fp or string.format("E%04X_%02X", finish, tonumber(rate, 16))
end

local eh, er = readTsv(EVENTS)
local sh, sr = readTsv(SUBS)
local keyById, registered = {}, {}
for _, r in ipairs(er) do
  if get(eh, r, "audio_type") == "ADPCM" then
    keyById[get(eh, r, "event_id")] = endKey(get(eh, r, "fingerprint"))
  end
end
for _, r in ipairs(sr) do
  local key = keyById[get(sh, r, "event_id")]
  if key and get(sh, r, "ko_text") ~= "" then registered[key] = true end
end

local file = assert(io.open(OUT, "w"))
file:write("result\tstart_frame\tend_frame\tkey\twrites\texecs\tpreloader_execs\tdiff_bytes\tnote\n")
local frame, wasPlaying, active = 0, false, nil

local function stateKey(s)
  local read, len, rate = s["cdrom.adpcm.readAddress"],
                          s["cdrom.adpcm.adpcmLength"],
                          s["cdrom.adpcm.playbackRate"]
  if type(read) ~= "number" or type(len) ~= "number" or type(rate) ~= "number" then return nil end
  local finish = (math.floor(read) + math.floor(len)) % 0x10000
  return finish == 0xFFFF
    and string.format("ADPCM_%04X_%04X_%02X", read, len, rate)
    or string.format("E%04X_%02X", finish, rate)
end

local function begin(key)
  local snap = {}
  for i = 0, SIZE - 1 do
    local value = emu.read(LO + i, mem) or 0
    snap[i] = value
    emu.write(AC_BASE + i, value, ac)
  end
  active = { key = key, start = frame, snap = snap, writes = 0, execs = 0, preload = 0 }
  emu.log(string.format("SUB BORROW shadow START %s frame %d: %d B -> AC $%06X",
    key, frame, SIZE, AC_BASE))
end

local function finish(note)
  if not active then return end
  local diff = 0
  for i = 0, SIZE - 1 do
    local saved = emu.read(AC_BASE + i, ac) or 0
    local now = emu.read(LO + i, mem) or 0
    if saved ~= active.snap[i] then error("AC mirror changed unexpectedly") end
    if now ~= active.snap[i] then diff = diff + 1 end
  end
  local pass = active.writes == 0 and active.execs == 0 and diff == 0
  file:write(string.format("%s\t%d\t%d\t%s\t%d\t%d\t%d\t%d\t%s\n",
    pass and "PASS" or "FAIL", active.start, frame, active.key, active.writes,
    active.execs, active.preload, diff, note or "")); file:flush()
  emu.log(string.format("SUB BORROW shadow %s %s: writes=%d execs=%d preloader=%d diff=%d",
    pass and "PASS" or "FAIL", active.key, active.writes, active.execs,
    active.preload, diff))
  active = nil
end

emu.addMemoryCallback(function(address)
  if active then active.writes = active.writes + 1 end
end, emu.callbackType.write, LO, HI, emu.cpuType.pce, cpu)

emu.addMemoryCallback(function(address)
  if active then
    active.execs = active.execs + 1
    if address == PRELOADER then active.preload = active.preload + 1 end
  end
end, emu.callbackType.exec, LO, HI, emu.cpuType.pce, cpu)

emu.addEventCallback(function()
  frame = frame + 1
  local ok, s = pcall(emu.getState); if not ok or not s then return end
  local playing = s["cdrom.adpcm.playing"] == true
  if playing and not wasPlaying then
    local key = stateKey(s)
    if key and registered[key] then begin(key) end
  elseif not playing and wasPlaying then
    finish("normal playback end")
  end
  wasPlaying = playing
  local label = active and ("SUB BORROW: " .. active.key) or "SUB BORROW: waiting registered ADPCM"
  emu.drawString(4, 4, label, active and 0x80FF80 or 0xFFFFFF, 0x80000000, 1)
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  finish("script stopped during playback")
  file:close()
end, emu.eventType.scriptEnded)

emu.log("PROBE_SUBTITLE_BORROW_SHADOW 0.1.0 loaded")
emu.log("  registered ADPCM only; no game RAM is overwritten")
emu.log("  output: " .. OUT)
