-- PROBE ADPCM RAM 0.1.1 -- 음성을 ADPCM RAM 에서 직접 떠낸다
--
-- 0.1.0 이 밝힌 것 (2026-08-20 실측, 재생 12 회)
-- ---------------------------------------------------------------------------
--   1. `pceAdpcmRam` (memType 63) 이 있다.  ADPCM RAM 은 읽을 수 있다.
--      덤프가 실패한 것은 출력 폴더가 없어서였다.
--
--   2. **`adpcmLength` 는 클립 길이가 아니라 버퍼에 차 있는 양이다.**
--      12 회 중 11 회가 `length = writeAddress - readAddress` 를 정확히 만족했다:
--
--          write  read  length   write-read
--          6800   006C  6794     6794  ✓
--          5800   0064  579C     579C  ✓
--          D000   0064  CF9C     CF9C  ✓
--          2000   0068  1F98     1F98  ✓
--          B800   006B  B795     B795  ✓
--          1800   005D  17A3     17A3  ✓
--
--      (안 맞은 하나는 프레임 1004 -- 부팅 직후 잔여 상태로 보인다.)
--      readAddress 는 전부 005D~0077, 즉 RAM 맨 앞이다.
--
--      따라서 **재생 시작 순간 readAddress 부터 length 바이트가 그 대사 전부**다.
--      0.1.0 은 writeAddress 에서 떴는데 그것은 끝점이었다.
--
--      길이도 맞는다: 0x6794 = 26,516 B -> 16 kHz 에서 3.3 초.  대사 한 줄이다.
--      voice_events 의 detected_duration 중앙값 3.317 초와 일치한다.
--
-- 왜 디스크가 아니라 RAM 인가
-- ---------------------------------------------------------------------------
-- 수집기(runtime_text_audit_0.2.1)가 적어 두는 값에는 디스크 좌표가 없다.
-- `sector` 는 `cdrom.scsi.sector` -- 드라이브가 마지막에 서비스한 자리이지 그
-- 대사의 위치가 아니다.  한 세션 12 개 이벤트가 전부 sector=002F0A 였다.
-- 그 좌표로 자른 클립은 대사 중간에서 끊긴다 (소유자 확인: "노도노 이타..." 끊김).
--
-- 게임이 이미 CD 에서 ADPCM RAM 으로 적재를 끝내고 거기서 재생한다.  디스크에서
-- 찾을 이유가 없다.
--
-- 바뀐 것
-- ---------------------------------------------------------------------------
--     시작 좌표   writeAddress -> **readAddress**
--     개수 제한   12 개 -> 없음 (플레이하는 만큼 다 뜬다)
--     파일 이름   재생 순서가 아니라 **내용 지문**으로 짓는다.  같은 대사를 다시
--                 들어도 같은 파일이 되어 저절로 중복 제거된다
--     폴더        없으면 첫 실패에서 크게 알린다 (조용히 지나가지 않는다)
--
-- 돌리는 법: 전원 투입부터, 대사를 들으면서.  Stop 을 눌러야 표가 닫힌다.
--   덤프 폴더가 미리 있어야 한다: dump/audio/ram/

local OUT      = "C:\\snatcher\\dump\\probe_adpcm_ram_0_1_1.tsv"
local DUMP_DIR = "C:\\snatcher\\dump\\audio\\ram\\"
local ADPCM_RAM_SIZE = 0x10000        -- 64 KB.  주소는 여기서 돈다

local file = assert(io.open(OUT, "w"))
file:write("kind\tframe\tread\twrite\tlength\tseconds\tfile\tnote\n")

local frame, seen, dumped, failed = 0, 0, 0, 0

local function row(kind, r, w, len, secs, name, note)
  file:write(string.format("%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\n", kind, frame,
    r or "", w or "", len or "", secs or "", name or "", note or ""))
  file:flush()
end

-- memType 을 이름으로 찾는다.  0.1.0 에서 pceAdpcmRam 이 있는 것이 확인됐지만
-- 숫자(63)를 박아 넣지 않는다 -- Mesen 판이 바뀌면 값이 밀릴 수 있다.
local ADPCM = emu.memType.pceAdpcmRam
if ADPCM == nil then
  for name, value in pairs(emu.memType) do
    if string.find(string.lower(name), "adpcm") then ADPCM = value end
  end
end
if ADPCM == nil then
  emu.log("★ ADPCM 메모리 타입이 없다.  0.1.0 을 다시 돌려 memType 목록을 볼 것")
  row("error", "", "", "", "", "", "ADPCM memType 없음")
end

local function st()
  local ok, s = pcall(emu.getState)
  if not ok then return nil end
  return s
end

-- 내용 지문.  전체를 훑지 않고 앞·중간·뒤를 성기게 뽑아 섞는다.  같은 대사면
-- 같은 값이 나오고, 다른 대사가 겹칠 일은 사실상 없다.
local function fingerprint(bytes)
  local h = 2166136261
  local step = math.max(1, math.floor(#bytes / 512))
  for i = 1, #bytes, step do
    h = (h ~ bytes:byte(i)) * 16777619 % 4294967296
  end
  return h
end

local wasPlaying = false

emu.addEventCallback(function()
  frame = frame + 1
  local s = st()
  if s == nil then return end
  local playing = s["cdrom.adpcm.playing"] == true

  if playing and not wasPlaying then
    seen = seen + 1
    local r    = s["cdrom.adpcm.readAddress"]  or 0
    local w    = s["cdrom.adpcm.writeAddress"] or 0
    local len  = s["cdrom.adpcm.adpcmLength"]  or 0
    local rate = s["cdrom.adpcm.playbackRate"] or 0
    -- 1 바이트 = 2 샘플 · rate 0E = 16 kHz (extract_adpcm.py 가 실측으로 확정)
    local secs = len * 2 / 16000

    -- length 가 write-read 와 어긋나면 적어 둔다.  0.1.0 에서 부팅 직후 한 건이
    -- 그랬다.  그런 것은 대사가 아닐 가능성이 높으니 나중에 걸러 낼 표식이 된다.
    local gap = (w - r) % ADPCM_RAM_SIZE
    local note = string.format("rate=%02X", rate)
    if gap ~= len then
      note = note .. string.format(" ★ write-read=%04X 인데 length=%04X", gap, len)
    end

    if ADPCM ~= nil and len > 0 then
      local buf, chunk = {}, {}
      for i = 0, len - 1 do
        chunk[#chunk + 1] = string.char(emu.read((r + i) % ADPCM_RAM_SIZE, ADPCM) or 0)
        if #chunk >= 4096 then buf[#buf + 1] = table.concat(chunk); chunk = {} end
      end
      if #chunk > 0 then buf[#buf + 1] = table.concat(chunk) end
      local data = table.concat(buf)

      -- 이름은 **내용**으로 짓는다.  재생 순서(sequence)는 세션 안에서만 유효해서
      -- 세션마다 1 부터 다시 세고, 실제로 서로 다른 대사가 같은 번호를 받았다
      -- (2026-08-20: 173 개 중 23 개 겹침).  지문은 세션을 넘어 같다.
      local name = string.format("v%08X_%04X.bin", fingerprint(data), len)
      local out = io.open(DUMP_DIR .. name, "wb")
      if out ~= nil then
        out:write(data); out:close()
        dumped = dumped + 1
        row("dump", string.format("%04X", r), string.format("%04X", w),
            string.format("%04X", len), string.format("%.2f", secs), name, note)
        emu.log(string.format("VOICE[%d] %s  %.2f s  read=%04X len=%04X",
          seen, name, secs, r, len))
      else
        failed = failed + 1
        row("dump", string.format("%04X", r), string.format("%04X", w),
            string.format("%04X", len), string.format("%.2f", secs), name,
            note .. " ★ 파일을 못 만든다")
        if failed == 1 then
          emu.log("★★★ 덤프 폴더가 없다.  만들고 다시 돌릴 것: " .. DUMP_DIR)
        end
      end
    else
      row("start", string.format("%04X", r), string.format("%04X", w),
          string.format("%04X", len), string.format("%.2f", secs), "", note)
    end
  end
  wasPlaying = playing
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  file:write(string.format("-- 프레임 %d · 재생 %d 회 · 떠낸 것 %d · 실패 %d\n",
    frame, seen, dumped, failed))
  file:close()
  emu.log(string.format("PROBE ADPCM RAM 0.1.1 종료 -- 재생 %d 회 · 떠낸 것 %d · 실패 %d",
    seen, dumped, failed))
end, emu.eventType.scriptEnded)

emu.log("PROBE ADPCM RAM 0.1.1 -- readAddress 부터 length 만큼 떠낸다")
emu.log("  전원 투입부터, 대사를 들으면서.  Stop 을 눌러야 표가 닫힌다")
emu.log("  덤프: " .. DUMP_DIR)
emu.log("  표:   " .. OUT)
