-- PROBE 1.0.2 - $FF 대신 부팅 값을 되돌려도 로드가 멀쩡한가 (빌드 없이 시험)
--
-- 어디까지 왔나
-- -------------
--   1.0.0  타이틀 스폰마다 $5B80 을 찍어 판정식을 정했다.  0.3.8.5-magic 이
--          부팅(세이브 유·무) · 저장->타이틀->로드 · 재저장->재로드 통과
--
--   남은 것  로드 -> 저장 -> 타이틀 -> **새로 시작** 에서 액션 메뉴가 깨진다.
--            복귀에 지운 것은 옳다.  문제는 그 뒤 캐시가 $FF 인데 부팅은
--            `82 FF FF 01 3E 00 00 82` 에서 출발한다는 것이다.
--
--   즉 남은 것은 "언제 지우나" 가 아니라 **"무엇을 써 넣나"** 다.
--
-- 이번 질문 -- 되돌리면 로드가 망가지지 않나
-- ------------------------------------------
--   $FF 가 로드를 고치는 원리는 "레코드 없음" 으로 읽혀 게임이 CD 에서 다시
--   채우게 만드는 것이다 (§0.1).  거기에 유효한 레코드를 써 넣으면 게임이
--   "있다" 고 보고 안 채운다 -- 그것도 로드한 장면과 무관한 접수처 레코드를.
--
--     82 ... 가 진짜 레코드다        되돌리면 로드가 망가진다.  이 갈래는 폐기
--     그게 게임의 "비어 있음" 표시다  되돌려도 로드는 그대로 채운다.  성립
--
--   두 번째일 여지가 있다 -- 바이트 1·2 가 FF FF 이고, 부팅 때 저 값이 있는데도
--   접수처 메뉴가 정상으로 그려졌다.  하지만 그것도 아직 추론이다.
--
--   64 B 를 케이브에 넣는 것은 자리가 없어 공사가 크다.  그 전에 **Lua 로
--   흉내낸다** -- 스텁이 지운 직후 부팅 값을 써 넣으면 되돌리기 판을 재빌드 없이
--   시험한 것과 같다 (PROBE 0.9.0 이 쓰던 방식).
--
-- 키
-- --
--   R   되돌리기 켜기/끄기.  화면 왼쪽 위에 RESTORE ON/OFF
--         OFF = 0.3.8.5-magic 그대로 ($FF 로 남는다)
--         ON  = 지운 직후 부팅 64 B 를 써 넣는다
--   Y   지금 캐시 64 B 를 MARK 행으로 찍는다 (새로 시작 직후에 누를 것)
--
-- 쓰는 법 -- 한 세션에서 네 번
-- ---------------------------
--   0.3.8.5-magic 에 걸고, 먼저 부팅을 한 번 지나 기준을 잡는다 (SPAWN 행에
--   "기준으로 잡음" 이 뜬다).  기준이 없으면 R 을 켜도 아무 일도 안 한다.
--
--     1) R=OFF · 저장 -> 타이틀 -> 로드            지금까지대로 정상이어야 한다
--     2) R=OFF · 저장 -> 타이틀 -> 새로 시작       깨진다 (지금 걸린 그것)
--     3) R=ON  · 저장 -> 타이틀 -> 새로 시작       **여기가 나아야 갈래가 산다**
--     4) R=ON  · 저장 -> 타이틀 -> 로드            **여기도 멀쩡해야 갈래가 산다**
--
--   3 이 낫고 4 가 깨지면 그 값은 진짜 레코드다 -- 되돌리기는 폐기하고 게임의
--   "적재됨" 표시를 직접 찾아야 한다.  3 과 4 가 둘 다 나으면 그대로 빌드로 옮긴다.
--
-- 옮길 때
-- -------
--   64 B 를 AC 에 두고 스텁이 블록 전송한다 (copy_record 의 템플릿 전송과 같은
--   방식).  set_ac + TAI 로 약 22 B 인데 케이브 여유가 6 B 뿐이라, 상수 검사
--   자리를 다시 빼거나 헬퍼를 줄여야 한다.  **먼저 이 프로브로 값어치를 확인할 것.**
--
--   base= 열이 64 B 가 정말 고정인지도 같이 답한다 (0 이면 기준과 완전히 같다).

local mem = emu.memType.pceMemory
local CB  = emu.memType.cpu

local STUB_ENTRY = 0x7CEF       -- title_cache_wipe ($BCEF), MPR3=$69 창
local CAVE_BANK  = 0x69

local CACHE = 0x5B80
local SPAN  = 64                -- 스텁이 지우는 폭 그대로

local ZP        = 0x2000
local SPAWN_PTR = ZP + 0xFA
local SPAWN_SHOW = 16

local function detectBuild()
  local ok, info = pcall(emu.getRomInfo)
  local name = ok and info and (info.name or info.path) or ""
  return name:match("%[KO ([^%]]+)%]") or "vanilla", name
end
local BUILD, ROM = detectBuild()

local OUT = string.format("C:\\snatcher\\dump\\probe_v102_%s_%s.tsv",
                          BUILD, os.date("%H%M%S"))
local file = assert(io.open(OUT, "w"))
file:write("kind\tframe\trestore\tbase\tspawn\tcache64\tcopies\twipes\tnote\n")
file:flush()

local frame, closed = 0, false
local spawns, wipes, copies, marks, lastKey = 0, 0, 0, 0, 0
local baseline = nil            -- 첫 부팅 값.  되돌릴 때 쓰는 것도 이것
local restore = false
local restores = 0

local function readByte(address)
  local ok, value = pcall(emu.read, address, mem, false)
  return (ok and type(value) == "number") and value or -1
end

local function grab(count)
  local bytes = {}
  for offset = 0, count - 1 do bytes[offset] = readByte(CACHE + offset) end
  return bytes
end

local function hex(bytes, count)
  local parts = {}
  for offset = 0, count - 1 do
    parts[#parts + 1] = string.format("%02X", bytes[offset])
  end
  return table.concat(parts, " ")
end

local function hexAt(address, count)
  local parts = {}
  for offset = 0, count - 1 do
    parts[#parts + 1] = string.format("%02X", readByte(address + offset))
  end
  return table.concat(parts, " ")
end

local function diffFromBase(bytes)
  if baseline == nil then return "-" end
  local n = 0
  for offset = 0, SPAN - 1 do
    if bytes[offset] ~= baseline[offset] then n = n + 1 end
  end
  return tostring(n)
end

local function mpr3()
  local ok, state = pcall(emu.getState)
  if not (ok and type(state) == "table") then return -1 end
  return state["memoryManager.mpr[3]"] or -1
end

local function row(kind, base, spawn, cache, note)
  if closed then return end
  file:write(string.format("%s\t%d\t%s\t%s\t%s\t%s\t%d\t%d\t%s\n",
    kind, frame, restore and "ON" or "OFF", base or "-", spawn or "-",
    cache or "-", copies, wipes, note or ""))
  file:flush()
end

local function spawnBytes()
  local lo, hi = readByte(SPAWN_PTR), readByte(SPAWN_PTR + 1)
  if lo < 0 or hi < 0 then return "ptr?" end
  local target = hi * 256 + lo
  return string.format("@%04X %s", target, hexAt(target, SPAWN_SHOW))
end

-- 스텁 진입 -- 지우기 **전** 64 B.  첫 부팅 값이 기준이 된다.
emu.addMemoryCallback(function()
  if closed then return end
  spawns = spawns + 1
  local bytes = grab(SPAN)

  local fresh = ""
  if baseline == nil and bytes[0] ~= 0xFF and bytes[0] ~= 0x53 then
    baseline = bytes
    fresh = "  <- 기준으로 잡음"
  end

  local bank = mpr3()
  row("SPAWN", diffFromBase(bytes), spawnBytes(), hex(bytes, SPAN),
      string.format("#%d  MPR3=%02X%s%s", spawns, bank,
                    bank == CAVE_BANK and "" or "  케이브 아님", fresh))
  emu.log(string.format("SPAWN #%d  f%d  base=%s  %s",
                        spawns, frame, diffFromBase(bytes), hex(bytes, 8)))
end, emu.callbackType.exec, STUB_ENTRY, STUB_ENTRY, emu.cpuType.pce, CB)

-- $5B80 쓰기.  FF 면 스텁이 지운 것이다.  되돌리기가 켜져 있으면 여기서 되돌린다.
--
-- 스텁은 $5BBF 부터 $5B80 까지 **내려오며** 쓰므로, $5B80 에 FF 가 쓰이는 순간이
-- 곧 마지막 바이트다.  그 다음에 써야 64 B 전체를 덮을 수 있다 -- 프레임 끝까지
-- 미루지 않고 여기서 바로 쓰는 이유다.
emu.addMemoryCallback(function(address, value)
  if closed then return end
  if value ~= 0xFF then
    copies = copies + 1
    if copies <= 3 or copies % 50 == 0 then
      row("fill", nil, nil, string.format("%02X", value), string.format("#%d", copies))
    end
    return
  end

  wipes = wipes + 1
  local note = string.format("#%d  스텁이 지웠다", wipes)

  if restore and baseline ~= nil then
    for offset = 0, SPAN - 1 do
      pcall(emu.write, CACHE + offset, baseline[offset], mem)
    end
    restores = restores + 1
    note = string.format("#%d  지운 뒤 부팅 값으로 되돌림 (restore #%d)", wipes, restores)
  elseif restore then
    note = string.format("#%d  RESTORE ON 인데 기준이 없다 -- 부팅을 먼저 지날 것", wipes)
  end

  row("WIPE", nil, nil, hex(grab(SPAN), SPAN), note)
  emu.log(string.format("WIPE #%d  f%d  %s", wipes, frame,
                        restore and "-> 되돌림" or "-> FF 유지"))
end, emu.callbackType.write, CACHE, CACHE, emu.cpuType.pce, CB)

emu.addEventCallback(function()
  frame = frame + 1

  if lastKey == 0 or frame - lastKey > 20 then
    if emu.isKeyPressed("R") then
      restore = not restore; lastKey = frame
      row("SET", nil, nil, nil,
          string.format("RESTORE %s%s", restore and "ON" or "OFF",
                        (restore and baseline == nil) and "  (기준 없음!)" or ""))
      emu.log("RESTORE " .. (restore and "ON" or "OFF"))
    elseif emu.isKeyPressed("Y") then
      marks = marks + 1; lastKey = frame
      local bytes = grab(SPAN)
      row("MARK", diffFromBase(bytes), nil, hex(bytes, SPAN),
          string.format("#%d", marks))
      emu.log(string.format("MARK #%d  f%d  base=%s  %s",
                            marks, frame, diffFromBase(bytes), hex(bytes, 8)))
    end
  end

  emu.drawString(4, 4, string.format("RESTORE %s   spawn %d  wipe %d  restore %d",
                                     restore and "ON " or "OFF", spawns, wipes, restores),
                 restore and 0x40FF40 or 0xFFFFFF, 0x000000, 1)
  if baseline == nil then
    emu.drawString(4, 14, "기준 없음 - 부팅을 한 번 지날 것", 0xFFFF40, 0x000000, 1)
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  row("census", nil, nil, baseline and hex(baseline, SPAN) or "기준 없음",
      string.format("spawn %d · wipe %d · restore %d · fill %d · mark %d · %s",
                    spawns, wipes, restores, copies, marks, ROM))
  closed = true
  file:close()
  emu.log("PROBE 1.0.2 -> " .. OUT)
end, emu.eventType.scriptEnded)

emu.log(string.format("PROBE 1.0.2 loaded  (빌드 %s)", BUILD))
emu.log("  R = 되돌리기 켜기/끄기 · Y = 지금 캐시 찍기")
emu.log("  부팅을 먼저 한 번 지나 기준을 잡을 것.  기준이 없으면 R 은 아무 일도 안 한다")
emu.log("  R=ON 에서 '새로 시작' 과 '로드' 가 **둘 다** 멀쩡해야 이 갈래가 산다")
