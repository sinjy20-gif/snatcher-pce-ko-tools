-- Subtitle temporal-borrow active POC 0.1.0
--
-- Shadow POC 0.1.0 proved that registered ADPCM playback leaves
-- $5B80-$5FFF untouched.  This is the next, deliberately minimal proof:
--
--   1. save the whole borrowed range and the IRQ1 vector in AC $1C0000;
--   2. install a five-byte IRQ1 chain stub at $5B80;
--   3. let the real IRQ1 path execute that stub while the registered voice plays;
--   4. restore the range and vector from AC, then compare every byte.
--
-- The stub is only `PHA / PLA / JMP original_irq1`.  It renders nothing and
-- changes no game state, so this POC isolates temporal borrowing and IRQ
-- chaining before the subtitle renderer is introduced.

local EVENTS = "C:/snatcher/snatcher_tool/translation/voice_events.tsv"
local SUBS   = "C:/snatcher/snatcher_tool/translation/voice_subtitles.tsv"
local OUT    = "C:/snatcher/dump/probe_subtitle_borrow_active_0_1_0.tsv"

local LO, HI, SIZE = 0x5B80, 0x5FFF, 0x480
local AC_BASE = 0x1C0000
local AC_VECTOR = AC_BASE + SIZE
local IRQ1_VECTOR = 0x2202
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
file:write("result\tstart_frame\tend_frame\tkey\tstub_execs\tunexpected_execs\tpreloader_execs\tgame_writes\tlive_ram_diff\tlive_vector_diff\trestore_ram_diff\trestore_vector_diff\tnote\n")

local frame, wasPlaying, active, monitoring = 0, false, nil, false

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

local function readByte(address, kind) return emu.read(address, kind) or 0 end

local function saveToAc()
  local snap = {}
  for i = 0, SIZE - 1 do
    local value = readByte(LO + i, mem)
    snap[i] = value
    emu.write(AC_BASE + i, value, ac)
  end
  local vectorLo = readByte(IRQ1_VECTOR, mem)
  local vectorHi = readByte(IRQ1_VECTOR + 1, mem)
  emu.write(AC_VECTOR, vectorLo, ac)
  emu.write(AC_VECTOR + 1, vectorHi, ac)
  return snap, vectorLo, vectorHi
end

local function installStub(vectorLo, vectorHi)
  -- Preserve A exactly, then continue at the original game IRQ1 handler.
  local code = { 0x48, 0x68, 0x4C, vectorLo, vectorHi } -- PHA; PLA; JMP vector
  for i, value in ipairs(code) do emu.write(LO + i - 1, value, mem) end
  emu.write(IRQ1_VECTOR, LO & 0xFF, mem)
  emu.write(IRQ1_VECTOR + 1, LO >> 8, mem)
  return code
end

local function restoreFromAc()
  for i = 0, SIZE - 1 do emu.write(LO + i, readByte(AC_BASE + i, ac), mem) end
  emu.write(IRQ1_VECTOR, readByte(AC_VECTOR, ac), mem)
  emu.write(IRQ1_VECTOR + 1, readByte(AC_VECTOR + 1, ac), mem)
end

local function begin(key)
  local snap, vectorLo, vectorHi = saveToAc()
  if vectorLo == 0 and vectorHi == 0 then error("IRQ1 vector is null; refusing active POC") end
  local code = installStub(vectorLo, vectorHi)
  active = {
    key = key, start = frame, snap = snap, vectorLo = vectorLo, vectorHi = vectorHi,
    code = code, stubExecs = 0, unexpectedExecs = 0, preloaderExecs = 0, writes = 0,
  }
  monitoring = true
  emu.log(string.format("SUB BORROW active START %s frame %d: IRQ1 $%02X%02X -> $%04X -> $%02X%02X",
    key, frame, vectorHi, vectorLo, LO, vectorHi, vectorLo))
end

local function finish(note)
  if not active then return end
  monitoring = false -- Do not count the POC's own restoration writes.

  local liveRamDiff, liveVectorDiff = 0, 0
  for i = 0, SIZE - 1 do
    local expected = active.snap[i]
    if i < #active.code then expected = active.code[i + 1] end
    if readByte(LO + i, mem) ~= expected then liveRamDiff = liveRamDiff + 1 end
  end
  if readByte(IRQ1_VECTOR, mem) ~= (LO & 0xFF) then liveVectorDiff = liveVectorDiff + 1 end
  if readByte(IRQ1_VECTOR + 1, mem) ~= (LO >> 8) then liveVectorDiff = liveVectorDiff + 1 end

  restoreFromAc()

  local restoreRamDiff, restoreVectorDiff = 0, 0
  for i = 0, SIZE - 1 do
    if readByte(LO + i, mem) ~= active.snap[i] then restoreRamDiff = restoreRamDiff + 1 end
    if readByte(AC_BASE + i, ac) ~= active.snap[i] then error("AC backup changed unexpectedly") end
  end
  if readByte(IRQ1_VECTOR, mem) ~= active.vectorLo then restoreVectorDiff = restoreVectorDiff + 1 end
  if readByte(IRQ1_VECTOR + 1, mem) ~= active.vectorHi then restoreVectorDiff = restoreVectorDiff + 1 end
  if readByte(AC_VECTOR, ac) ~= active.vectorLo or readByte(AC_VECTOR + 1, ac) ~= active.vectorHi then
    error("AC IRQ1 backup changed unexpectedly")
  end

  local pass = active.stubExecs > 0 and active.unexpectedExecs == 0 and active.writes == 0
    and liveRamDiff == 0 and liveVectorDiff == 0 and restoreRamDiff == 0 and restoreVectorDiff == 0
  file:write(string.format("%s\t%d\t%d\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\n",
    pass and "PASS" or "FAIL", active.start, frame, active.key, active.stubExecs,
    active.unexpectedExecs, active.preloaderExecs, active.writes, liveRamDiff,
    liveVectorDiff, restoreRamDiff, restoreVectorDiff, note or ""))
  file:flush()
  emu.log(string.format(
    "SUB BORROW active %s %s: stub=%d unexpectedExec=%d writes=%d liveDiff=%d/%d restoreDiff=%d/%d",
    pass and "PASS" or "FAIL", active.key, active.stubExecs, active.unexpectedExecs,
    active.writes, liveRamDiff, liveVectorDiff, restoreRamDiff, restoreVectorDiff))
  active = nil
end

emu.addMemoryCallback(function()
  if monitoring and active then active.writes = active.writes + 1 end
end, emu.callbackType.write, LO, HI, emu.cpuType.pce, cpu)

emu.addMemoryCallback(function(address)
  if not (monitoring and active) then return end
  -- PHA, PLA, and JMP are all part of our five-byte chain stub.  The first
  -- version counted only its entry byte ($5B80), so every healthy IRQ looked
  -- like two unexpected executions at $5B81/$5B82.
  if address >= LO and address < LO + #active.code then
    active.stubExecs = active.stubExecs + 1
  else
    active.unexpectedExecs = active.unexpectedExecs + 1
    if address == PRELOADER then active.preloaderExecs = active.preloaderExecs + 1 end
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
  local label = active and ("SUB ACTIVE: " .. active.key) or "SUB ACTIVE: waiting registered ADPCM"
  emu.drawString(4, 4, label, active and 0x80FF80 or 0xFFFFFF, 0x80000000, 1)
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  finish("script stopped during playback")
  file:close()
end, emu.eventType.scriptEnded)

emu.log("PROBE_SUBTITLE_BORROW_ACTIVE 0.1.0 loaded")
emu.log("  registered ADPCM only; installs a PHA/PLA/JMP IRQ1 chain stub during playback")
emu.log("  PASS requires stub execution, no game writes, and byte-exact RAM/vector restoration")
emu.log("  output: " .. OUT)
