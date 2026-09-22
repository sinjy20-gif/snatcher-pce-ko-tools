-- ADPCM/CD-DA 음성 수집 전용.  text/UI/subtitle/VRAM 에 한 바이트도 안 쓴다.
--
-- 0.1.5 -- 2026-09-01  ★ 8.19 초에서 잘리던 음성을 채운다 (0.1.4 의 링 헛돎을 고침)
-- ===========================================================================
--
-- 0.1.2 의 결함 (원인)
--   재생이 **시작되는 순간** ADPCM RAM 을 한 번만 떴다.  ADPCM RAM 은 64 KB
--   링버퍼고 게임은 재생하면서 계속 채워 넣는다(스트리밍).  그래서 한 판
--   분량인 8.19 초까지만 담겼다.
--
--     실측(2026-09-01)  클립 990 개 중 65,400 B 이상이 **161 개**
--                       마스터 커버리지 95% 미만이 **142 행**
--                         ADPCM_004DEB_FFFF_0E  8.18 초 담김 / 13.53 초 재생 = 60 %
--                         ADPCM_004D71_FFFF_0E  8.18 초 담김 / 12.77 초 재생 = 64 %
--                       정상 클립은 99~100 % 로 떨어진다 (846 행)
--     소리만 잘린 게 아니라 그 소리로 뜬 **일본어 전사도 앞 8 초치뿐**이다.
--
-- 0.1.3 이 못 고친 것
--   이어붙이기는 맞게 했는데 **이어붙인 결과를 파일에 못 썼다.**
--       if #data > #old and endsWith(data, old)      -- 옛 파일이 새 데이터의 꼬리인가
--   꼬리로 자라면 옛 파일은 새 데이터의 **머리(prefix)** 다.  판정이 다 빗나가
--   `k..._vXXXXXXXX.bin` 변종으로 새 나가고, 마스터의 clip_file 은 잘린 옛 파일을
--   그대로 가리킨다.  0.1.3 만 돌리면 증상이 그대로 남는다.
--
-- 0.1.4 가 못 고친 것 -- ★ 링을 한 바퀴 헛돌았다 (2026-09-01 본부 주행에서 확인)
--   커서에서 포인터까지의 **모듈로 전방 거리**를 새로 채워진 양으로 봤다.
--   머리를 뜬 직후 커서는 `read+length`($D000) 인데 read 는 아직 앞쪽($0064) 이다.
--       (0x0064 - 0xD000) mod 0x10000 = 0x3064 = 12,388 B    <- 작아 보인다
--   실제로는 read 가 커서보다 **뒤에** 있는 것이다.  전방 거리로는 앞섰는지
--   뒤졌는지 구분할 수 없다.  그래서 12 KB 를 헛붙이고 커서를 read 로 당긴 뒤
--   다시 끝까지 따라가, 결과가 **정확히 링 한 바퀴(65,536 B)** 불었다.
--   오염된 19 개가 전부 그 값이었다 (tools/restore_voice_clips.py 로 전량 복구).
--
--   0.1.5 는 **펼친 누적 전진량(accAdv)** 을 센다.  한 프레임 전진량은 16 kHz 에서
--   133 B 라 절대 크지 않고, 링을 몇 바퀴 돌든 accAdv 는 계속 는다.  담을 것이
--   생기는 조건은 `accAdv > accBytes` 하나뿐이다.
--
-- ===========================================================================
-- 0.1.5 의 설계 -- 어느 포인터를 따라가나
-- ===========================================================================
--
-- 실측(v012 로그 3,471 START):
--     write == read + adpcmLength   2,247 회
--     write >  read + adpcmLength   나머지.  최대 18 KB 앞서 있다
--
-- 즉 **write 는 이 클립의 끝이 아니다.**  CD 가 다음 것까지 미리 채워 둔 자리다.
-- write 만 따라가면 다음 클립 데이터를 꼬리에 붙인다 (전사가 오염된다).
--
-- 그래서 **read 포인터(실제로 재생된 만큼)** 를 따라간다.
--
--     머리   readAddress 에서 adpcmLength 바이트   <- 0.1.2 와 **바이트가 같다**
--            (그래서 옛 파일이 새 데이터의 prefix 가 되어 성장 판정이 성립한다)
--     이후   누적 전진량이 머리 길이를 넘어선 만큼만 이어붙인다
--            (길이 레지스터가 다시 걸린 것 = 스트리밍의 다음 조각)
--     끝     재생이 멈추면 한 번 더 훑는다
--
-- 한 프레임 전진량이 4,096 B 를 넘으면 포인터가 리셋된 것이다 (16 kHz = 133 B).
-- 그때는 **붙이지 않고 재동기**하고 건너뛴 양을 로그에 남긴다 -- 조용히 틀린
-- 데이터를 붙이느니 구멍이 보이는 편이 낫다.
--
-- ⚠ readAddress 가 살아 있는 값이 아닐 가능성에 대비한다.  재생 30 프레임 동안
--   read 가 한 번도 안 움직이고 write 만 움직이면 **write 추적으로 갈아탄다**
--   (로그에 크게 찍는다).  둘 중 무엇이 맞는지 첫 주행의 로그가 답한다.
--
-- ===========================================================================
--
-- ★ 키와 파일 이름은 한 글자도 안 바뀐다.
--   ADPCM_<sector>_<end>_<rate> · end=(readAddress+adpcmLength)&0xFFFF ·
--   재생 시작 순간 한 번만 계산.  마스터 1,055 행과 그대로 맞물린다.
--   (0.5.47-vram-key-map-0.4 의 actualAdpcmVoice 와도 같은 계산이다)
--
-- ★ 클립 폴더도 안 바뀐다 -- 자란 것은 제자리에서 덮어쓴다.
--   주행이 끝나면  python tools/replace_master_voice.py --write
--
-- 로그는 v014 로 새로 쓴다 (열이 늘었다).  occurrence 는 v012 도 같이 읽어 잇는다.

local ADPCM = emu.memType.pceAdpcmRam
local OUT   = "C:/snatcher/snatcher_tool/logs/voice_key_events_raw_v014.tsv"
local OLD   = "C:/snatcher/snatcher_tool/logs/voice_key_events_raw_v012.tsv"
local CLIPS = "C:/snatcher/snatcher_tool/logs/voice_clips_v012_fresh/"

local RAM_SIZE     = 0x10000
local CDDA_GRACE   = 12
local FLUSH_EVERY  = 300        -- 프레임.  긴 클립 중간 저장 (에뮬이 죽어도 남는다)
local CAP_WARN     = 65400      -- 이 이상이면 아직 64 KB 한 판에 붙어 있다
local MODE_DECIDE  = 30         -- 프레임.  read 가 살아 있는 값인지 판정하는 창
local JUMP_WARN    = 4096       -- 한 프레임 전진 상한.  16 kHz 는 133 B/프레임이라
                                --   이걸 넘으면 포인터 리셋이다 -> 붙이지 않고 재동기
local MAX_BYTES    = 8000 * 90  -- 90 초.  폭주 방지

local session = (os and os.date) and os.date("%Y%m%d_%H%M%S") or "session"
local seq, wasPlaying, active = 0, false, nil
-- 0.1.5 누적 상태
--   accStart   이 클립이 시작된 ADPCM RAM 주소 (머리의 첫 바이트)
--   accBytes   지금까지 파일에 담은 바이트 수 (= accStart 로부터 연속)
--   accAdv     포인터가 **펼쳐서** 전진한 총량.  링을 몇 바퀴 돌든 계속 는다
--   accPrev    직전 프레임의 포인터 값 (전진량을 재는 기준)
local acc, accStart, accBytes, accAdv, accPrev = nil, 0, 0, 0, 0
local accJumps, accLost, accTrunc = 0, 0, false
local ptrMode, modeFrames, firstRead, firstWrite = "read", 0, nil, nil
local lastEndFrame, lastEndKey = nil, nil
local cdda, cddaPrev, cddaLast = nil, nil, nil
local occurrences = {}
local stats = { started = 0, done = 0, grown = 0, capped = 0, wrote = 0 }

local HEADER = "event_type\tevent_id\tsequence\tframe\taudio_type\tkey_text\tkey_hex\t"
            .. "read_address\twrite_address\tend_address\taudio_length\tplayback_rate\tsector\t"
            .. "clip_file\tduration_frames\toccurrence\tstatus\t"
            .. "bytes_captured\tptr_mode\tseconds_captured\tseconds_played\tcoverage_pct\t"
            .. "jumps\tcontinuation\n"

local function number(s, key)
  local v = s[key]
  return type(v) == "number" and math.floor(v) or 0
end

-- PCE ADPCM: 표본율 = 32000/(16-rate) Hz · 4 bit -> 1 B 당 2 표본.
-- rate 0x0E -> 16000 Hz -> 8000 B/s -> 64 KB = 8.192 초.  실측과 정확히 맞는다.
local function bytesPerSecond(rate)
  if rate == nil or rate >= 16 then return 8000 end
  return (32000 / (16 - rate)) / 2
end

local function ensureHeader()
  local f = io.open(OUT, "rb"); local empty = f == nil
  if f then empty = (f:seek("end") or 0) == 0; f:close() end
  if not empty then return true end
  f = io.open(OUT, "ab")
  if not f then emu.log("VOICE ERROR opening " .. OUT); return false end
  f:write(HEADER); f:close(); return true
end

local function splitTsv(line)
  local cols = {}
  for cell in (line .. "\t"):gmatch("(.-)\t") do cols[#cols + 1] = cell end
  return cols
end

local function loadOccurrencesFrom(path)
  local f = io.open(path, "rb"); if not f then return 0 end
  local loaded = 0
  f:read("*l")
  for line in f:lines() do
    local cols = splitTsv(line)
    if cols[1] == "START" and cols[6] and cols[6] ~= "" then
      occurrences[cols[6]] = (occurrences[cols[6]] or 0) + 1
      loaded = loaded + 1
    end
  end
  f:close()
  return loaded
end

local function append(kind, item, frame, status)
  local f = io.open(OUT, "ab")
  if not f then emu.log("VOICE ERROR appending " .. OUT); return end
  local played = math.max(0, frame - (item.startFrame or frame)) / 60
  local secs   = (item.bytesCaptured or 0) / bytesPerSecond(item.rate)
  local cover  = (played > 0.05) and (secs / played * 100) or 0
  f:write(string.format(
    "%s\t%s\t%d\t%d\t%s\t%s\t%s\t%04X\t%04X\t%04X\t%04X\t%02X\t%06X\t%s\t%d\t%d\t%s\t%d\t%s\t%.2f\t%.2f\t%.1f\t%d\t%s\n",
    kind, item.id, item.sequence, frame, item.audioType, item.keyText, item.keyHex,
    item.readAddress or 0, item.writeAddress or 0, item.endAddress or 0,
    item.length or 0, item.rate or 0, item.sector or 0, item.clip or "",
    math.max(0, frame - (item.startFrame or frame)),
    item.occurrence or 1, status or "ok",
    item.bytesCaptured or 0, item.ptrMode or "", secs, played, cover,
    item.jumps or 0, item.continuation or ""))
  f:flush(); f:close()
end

local function fingerprint(data)
  local h = 2166136261
  local step = math.max(1, math.floor(#data / 512))
  for i = 1, #data, step do h = (h ~ data:byte(i)) * 16777619 % 4294967296 end
  return h
end

local function readClipData(from, length)
  if length <= 0 then return "" end
  local blocks, chunk = {}, {}
  for i = 0, length - 1 do
    chunk[#chunk + 1] = string.char(emu.read((from + i) % RAM_SIZE, ADPCM) or 0)
    if #chunk >= 4096 then blocks[#blocks + 1] = table.concat(chunk); chunk = {} end
  end
  if #chunk > 0 then blocks[#blocks + 1] = table.concat(chunk) end
  return table.concat(blocks)
end

local function readFile(path)
  local f = io.open(path, "rb"); if not f then return nil end
  local data = f:read("*a"); f:close(); return data
end
local function writeFile(path, data)
  local f = io.open(path, "wb"); if not f then return false end
  f:write(data); f:close(); return true
end
local function startsWith(longer, shorter)
  return #shorter <= #longer and longer:sub(1, #shorter) == shorter
end
local function endsWith(longer, shorter)
  return #shorter <= #longer and longer:sub(#longer - #shorter + 1) == shorter
end

-- 네이티브 6 B 키 하나당 파일 하나.  같은 스트림이면 **가장 긴 것**을 남긴다.
--   prefix 로 자람  스트리밍 누적 (꼬리가 붙는다)          -> 덮어쓴다  ★0.1.5
--   suffix 로 자람  readAddress 가 앞선 포착 (머리가 붙는다) -> 덮어쓴다
--   둘 다 아니면    정말 다른 바이트.  둘 다 보존하고 표시한다
-- partial=true 면 중간 저장이다.  **변종 파일을 만들지 않는다** --
-- 본부 주행에서 003318 하나에 변종이 3 개 생겼다 (300 프레임마다 한 개씩).
local function dumpClipData(keyText, data, partial)
  if ADPCM == nil or data == nil or #data <= 0 then return "", "no_adpcm_ram" end
  local stem = "k" .. keyText:sub(7)
  local name = stem .. ".bin"
  local path = CLIPS .. name
  local old  = readFile(path)
  if old then
    if old == data then return name, "existing_key" end
    if #data > #old then
      if startsWith(data, old) then
        if not writeFile(path, data) then return "", "dump_failed" end
        return name, "expanded_tail"
      end
      if endsWith(data, old) then
        if not writeFile(path, data) then return "", "dump_failed" end
        return name, "expanded_key"
      end
    else
      if startsWith(old, data) then return name, "existing_key_head" end
      if endsWith(old, data) then return name, "existing_key_tail" end
    end
    -- 머리가 몇 바이트 어긋난 채로 자란 경우.  readAddress 는 주행마다 수십 바이트
    -- 흔들린다 (실측 $0011~$0079).  그러면 prefix 도 suffix 도 안 맞아 변종 파일로
    -- 새 나간다 -- 본부 주행에서 003318 · 0033D7 · 003423 이 그렇게 갈렸다.
    -- 앞쪽 128 B 안에서 옛 파일이 통째로 들어앉는 자리를 찾으면 같은 스트림이다.
    if #data > #old then
      for k = 1, 128 do
        if k + #old - 1 > #data then break end
        if data:sub(k, k + #old - 1) == old then
          if not writeFile(path, data) then return "", "dump_failed" end
          return name, "expanded_shifted"
        end
      end
    end
    -- ★ 반대쪽 -- 새 포착이 옛 것보다 **늦게** 시작한 경우.
    --   readAddress 는 주행마다 몇 바이트 흔들린다 (실측 $0011~$0079).
    --   본부 주행에서 003318(2 B) · 0033D7(9 B) · 003423(2 B) 가 이래서
    --   내용은 100 % 인데 이름만 변종으로 갈렸다.
    --   옛 파일의 앞 k 바이트를 앞에 붙여 온전한 클립으로 되살린다.
    for k = 1, 128 do
      local n = #old - k
      if n < 1024 then break end
      if n > #data then n = #data end
      if old:sub(k + 1, k + n) == data:sub(1, n) then
        local merged = old:sub(1, k) .. data
        if #merged > #old then
          if not writeFile(path, merged) then return "", "dump_failed" end
          return name, "expanded_prepend"
        end
        return name, "existing_key_head"
      end
    end
    if partial then return name, "partial_no_match" end   -- 변종을 만들지 않는다
    local variant = string.format("%s_v%08X.bin", stem, fingerprint(data))
    local vpath = CLIPS .. variant
    if readFile(vpath) == data then return variant, "key_collision_existing" end
    if not writeFile(vpath, data) then return "", "dump_failed" end
    return variant, "key_collision_saved"
  end
  if not writeFile(path, data) then return "", "dump_failed" end
  return name, "saved_key"
end

local function adpcmKey(sector, endAddress, rate)
  local text = string.format("ADPCM_%06X_%04X_%02X", sector, endAddress, rate)
  local hex = string.format("%02X %02X %02X %02X %02X %02X",
    sector & 0xFF, (sector >> 8) & 0xFF, (sector >> 16) & 0xFF,
    endAddress & 0xFF, (endAddress >> 8) & 0xFF, rate & 0xFF)
  return text, hex
end

local function startAdpcm(s, frame)
  seq = seq + 1
  stats.started = stats.started + 1
  local sector       = number(s, "cdrom.scsi.sector")
  local writeAddress = number(s, "cdrom.adpcm.writeAddress")
  local readAddress  = number(s, "cdrom.adpcm.readAddress")
  local length       = number(s, "cdrom.adpcm.adpcmLength")
  local endAddress   = (readAddress + length) % RAM_SIZE
  local rate         = number(s, "cdrom.adpcm.playbackRate")
  local keyText, keyHex = adpcmKey(sector, endAddress, rate)
  occurrences[keyText] = (occurrences[keyText] or 0) + 1

  -- 머리 = 0.1.2 와 바이트가 같다.  옛 파일이 prefix 가 되어야 성장 판정이 선다.
  acc      = { readClipData(readAddress, length) }
  accBytes = #acc[1]
  accStart = readAddress
  accAdv   = 0                       -- 아직 한 바이트도 안 전진했다
  accPrev  = readAddress
  accJumps, accLost, accTrunc = 0, 0, false
  ptrMode, modeFrames = "read", 0
  firstRead, firstWrite = readAddress, writeAddress

  local continuation = ""
  if lastEndFrame and (frame - lastEndFrame) <= 3 then
    continuation = string.format("after:%s+%df", tostring(lastEndKey), frame - lastEndFrame)
  end

  active = { id = string.format("%s_%04d", session, seq), sequence = seq, audioType = "ADPCM",
             keyText = keyText, keyHex = keyHex, readAddress = readAddress,
             writeAddress = writeAddress, endAddress = endAddress, length = length,
             rate = rate, sector = sector, clip = "k" .. keyText:sub(7) .. ".bin",
             startFrame = frame, lastFlush = frame, occurrence = occurrences[keyText],
             bytesCaptured = accBytes, ptrMode = ptrMode, jumps = 0,
             continuation = continuation }
  append("START", active, frame, "collecting")
  emu.log(string.format("VOICE START[%d] %s head=%d B (len=%04X read=%04X write=%04X) %s",
    seq, keyText, accBytes, length, readAddress, writeAddress,
    continuation ~= "" and ("★" .. continuation) or ""))
end

-- 재생 중 **재생된 만큼** 이어붙인다.
--
-- ★ 0.1.5 -- 모듈로 전방 거리를 쓰면 안 된다 (2026-09-01 실측으로 확인)
--
--   0.1.4 는 커서에서 포인터까지의 **전방** 거리를 새로 채워진 양으로 봤다.
--   머리를 뜬 직후 커서는 `read+length`(예 $D000) 인데 read 는 아직 버퍼
--   앞쪽($0064) 이다.  그러면
--
--       (0x0064 - 0xD000) mod 0x10000 = 0x3064 = 12,388 B    <- 작아 보인다
--
--   실제로는 read 가 커서보다 0xCF9C **뒤에** 있는 것이다.  전방 거리로는
--   "앞섰다/뒤졌다" 를 구분할 수 없다.  그래서 12 KB 를 헛붙이고 커서를 read 로
--   당긴 뒤 다시 끝까지 따라가, 결과가 **정확히 링 한 바퀴(65,536 B)** 불었다.
--   본부 주행에서 오염된 19 개가 전부 그 값이었다.
--
--   그래서 이제 **펼친 누적 전진량(accAdv)** 을 센다.  한 프레임 전진량은
--   16 kHz 에서 133 B 라 절대 작지 않고, 링을 몇 바퀴 돌든 accAdv 는 계속 는다.
--   담을 것이 생기는 조건은 `accAdv > accBytes` 하나뿐이고, 읽어 올 자리는
--   `accStart + accBytes` 로 명확하다.
local function adpcmTick(s)
  if not active or acc == nil then return end

  local r = number(s, "cdrom.adpcm.readAddress")
  local w = number(s, "cdrom.adpcm.writeAddress")

  -- read 가 살아 있는 값인지 첫 30 프레임 안에 판정한다
  if ptrMode == "read" and modeFrames < MODE_DECIDE then
    modeFrames = modeFrames + 1
    if modeFrames == MODE_DECIDE and r == firstRead and w ~= firstWrite then
      ptrMode = "write"
      active.ptrMode = "write"
      accPrev = w
      emu.log("VOICE ★★ readAddress 가 안 움직인다 -- writeAddress 추적으로 갈아탄다"
              .. " (이 주행의 꼬리에 다음 클립이 섞일 수 있다)")
    end
  end

  local p = (ptrMode == "read") and r or w
  local step = (p - accPrev) % RAM_SIZE
  if step == 0 then return end
  if step > JUMP_WARN then
    -- 한 프레임에 이만큼 전진할 수 없다 (16 kHz = 133 B/프레임).
    -- 포인터가 리셋됐거나 다른 버퍼로 갈아탄 것이다.  **붙이지 않고** 재동기한다.
    accJumps = accJumps + 1
    accLost = accLost + step
    active.jumps = accJumps
    accPrev = p
    return
  end
  accAdv = accAdv + step
  accPrev = p

  if accAdv <= accBytes then return end          -- 아직 머리 안이다
  local n = accAdv - accBytes
  if accBytes + n > MAX_BYTES then
    if not accTrunc then
      accTrunc = true
      emu.log(string.format("VOICE ★★ %s 가 %d B 를 넘었다 -- 여기서 멈춘다 (폭주 방지)",
        active.keyText, MAX_BYTES))
    end
    return
  end
  acc[#acc + 1] = readClipData((accStart + accBytes) % RAM_SIZE, n)
  accBytes = accBytes + n
  active.bytesCaptured = accBytes
end

local function flushPartial(frame)
  if not active or acc == nil or accBytes <= 0 then return end
  if frame - (active.lastFlush or frame) < FLUSH_EVERY then return end
  active.lastFlush = frame
  dumpClipData(active.keyText, table.concat(acc), true)   -- partial
end

local function endAdpcm(frame, status)
  if not active then return end
  local expected = active.clip
  local data = acc and table.concat(acc) or ""
  local clip, dumpStatus = dumpClipData(active.keyText, data)
  active.clip = (clip ~= "") and clip or expected
  active.bytesCaptured = accBytes
  active.ptrMode = ptrMode
  active.jumps = accJumps

  local played = (frame - active.startFrame) / 60
  local secs   = accBytes / bytesPerSecond(active.rate)
  local cover  = played > 0.05 and (secs / played * 100) or 0
  stats.done = stats.done + 1
  if dumpStatus == "expanded_tail" or dumpStatus == "expanded_key"
     or dumpStatus == "expanded_shifted" or dumpStatus == "expanded_prepend" then
    stats.grown = stats.grown + 1
  end
  if dumpStatus ~= "existing_key" and dumpStatus ~= "existing_key_head"
     and dumpStatus ~= "existing_key_tail" and dumpStatus ~= "no_adpcm_ram"
     and dumpStatus ~= "partial_no_match" then
    stats.wrote = stats.wrote + 1
  end
  if played > 0.05 and cover < 95 then
    stats.capped = stats.capped + 1
    emu.log(string.format("VOICE ★★ 아직 짧다 %s -- %.2f초 담김 / %.2f초 재생 = %.0f%%",
      active.keyText, secs, played, cover))
  end
  if clip ~= "" and clip ~= expected then
    emu.log(string.format("VOICE ★ 이름이 갈렸다 %s -> %s (키 충돌)", expected, clip))
  end
  if accJumps > 0 then
    emu.log(string.format(
      "VOICE  포인터 도약 %d 회 · 건너뛴 %d B -- 붙이지 않고 재동기했다 (구멍이 있을 수 있다)",
      accJumps, accLost))
  end
  emu.log(string.format("VOICE DUMP %s %d B (%.2f초 담김 / %.2f초 재생 = %.0f%%) [%s] %s",
    active.keyText, accBytes, secs, played, cover, ptrMode, dumpStatus))

  acc, accStart, accBytes, accAdv, accPrev = nil, 0, 0, 0, 0
  accJumps, accLost, accTrunc = 0, 0, false
  append("END", active, frame, status or dumpStatus)
  lastEndFrame, lastEndKey = frame, active.keyText
  active = nil
end

local function cddaKey(sector) return string.format("CDDA_%06X", sector) end

local function cddaTick(s, frame)
  local sector = s["cdrom.audioPlayer.currentSector"]
  local function finish(status)
    if not cdda then return end
    append("END", cdda, frame, status or "complete")
    emu.log(string.format("CDDA END[%d] %06X-%06X duration=%.3fs",
      cdda.sequence, cdda.sector, cdda.lastSector, (frame - cdda.startFrame) / 60))
    cdda = nil; cddaLast = nil
  end
  if type(sector) ~= "number" then
    cddaPrev = nil
    if cdda and cddaLast and frame - cddaLast >= CDDA_GRACE then finish("complete") end
    return
  end
  sector = math.floor(sector)
  if cddaPrev == nil then cddaPrev = sector; return end
  if sector ~= cddaPrev then
    if not cdda then
      seq = seq + 1
      local key = cddaKey(sector)
      occurrences[key] = (occurrences[key] or 0) + 1
      cdda = { id = string.format("%s_%04d", session, seq), sequence = seq, audioType = "CDDA",
               keyText = key, keyHex = "", readAddress = sector & 0xFFFF,
               writeAddress = (sector >> 16) & 0xFFFF, length = 0, rate = 0, sector = sector,
               clip = "", startFrame = frame, lastSector = sector,
               occurrence = occurrences[key], bytesCaptured = 0, ptrMode = "", jumps = 0 }
      append("START", cdda, frame, "range_only")
      emu.log(string.format("CDDA START[%d] sector=%06X", seq, sector))
    else
      cdda.lastSector = sector
    end
    cddaLast = frame
  elseif cdda and cddaLast and frame - cddaLast >= CDDA_GRACE then
    finish("complete")
  end
  cddaPrev = sector
end

assert(ensureHeader(), "cannot create voice collection log")
local o1 = loadOccurrencesFrom(OUT)
local o2 = loadOccurrencesFrom(OLD)

emu.addEventCallback(function()
  local s = emu.getState() or {}
  local frame = number(s, "frameCount")
  local playing = s["cdrom.adpcm.playing"] == true
  if playing and not wasPlaying then
    startAdpcm(s, frame)
  elseif playing and wasPlaying then
    adpcmTick(s); flushPartial(frame)
  elseif not playing and wasPlaying then
    adpcmTick(s); endAdpcm(frame, nil)
  end
  wasPlaying = playing
  cddaTick(s, frame)
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  local s = emu.getState() or {}
  local frame = number(s, "frameCount")
  if active then endAdpcm(frame, "script_stopped") end
  if cdda then append("END", cdda, frame, "script_stopped") end
  emu.log(string.format(
    "VOICE 요약 -- 시작 %d · 완료 %d · 파일에 쓴 것 %d · 자란 것 %d · 아직 짧은 것 %d",
    stats.started, stats.done, stats.wrote, stats.grown, stats.capped))
  emu.log("  다음:  python tools/replace_master_voice.py        (미리보기)")
  emu.log("         python tools/replace_master_voice.py --write (마스터 갱신)")
end, emu.eventType.scriptEnded)

emu.log("COLLECT_VOICE_KEYS_AUDIO 0.1.5 loaded -- 음성 전용 · read 포인터 누적 · 제자리 덮어쓰기")
emu.log("  ★ 0.1.5: 펼친 누적 전진량으로 센다 -> 0.1.4 의 링 한 바퀴(+65,536 B) 헛돎을 고쳤다")
emu.log("  ★ 머리는 0.1.2 와 바이트가 같다 -> 옛 파일이 prefix 가 되어 이어서 자란다")
emu.log("  ★ write 가 아니라 read 를 따라간다 -> 다음 클립이 꼬리에 안 섞인다")
emu.log("  키/파일이름 불변 -- 마스터 1,055 행과 그대로 맞물린다")
emu.log("  text/UI/subtitle/VRAM writes 0 B")
emu.log(string.format("  이전 occurrence: v014 %d · v012 %d", o1, o2))
emu.log("  events: " .. OUT)
emu.log("  clips : " .. CLIPS)
