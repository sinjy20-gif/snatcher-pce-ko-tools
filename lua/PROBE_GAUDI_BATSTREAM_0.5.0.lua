-- PROBE GAUDI BAT STREAM 0.5.0 -- 자판 타일맵 스트림을 잡는다.  ★순수 관측 · 쓰기 0 B
--
-- 확정된 것 (2026-09-14 실측)
--   자판 패널은 `$6DA0` (뱅크 $69) 의 **바이트 스트림 인터프리터**가 그린다.
--
--     $6DC4  LDA ($00),Y        스트림에서 한 바이트
--     $6DC7  CMP #$FF  -> 끝
--     $6DCB  CMP #$FE  -> 다음 2 B = 새 VRAM 주소
--     $6DCF  CMP #$FD  -> 다음 1 B = 새 속성 상위바이트 ($04)
--     $6DD8  STA $0002          그 밖엔 타일 번호 하위바이트
--     $6DE0  STX $0003          상위바이트는 $04
--
--   VRAM 증가값이 64 라 한 칸 쓰면 바로 아래 칸이다.  그래서 스트림은
--   키마다 (위,아래) 를 쓰고 `$FE` 로 다음 열로 뛴다 -- 행 단위 연속이 아니다.
--   그래서 "행 하위바이트열" 로 디스크를 뒤진 검색이 전부 빗나갔다.
--
--   ⚠ 제로페이지는 프레임이 끝나면 이미 딴 데 쓰인다.  **호출 순간**에 떠야 한다.
--
-- 잡는 것
--   `$6DA0` 입구마다 포인터 `$00/$01` · 속성 `$04` · `$03` · Y · MPR 8 개를 찍고,
--   포인터가 가리키는 곳에서 1 KB 를 뜬다.  서로 다른 포인터마다 한 번씩.
--
-- 쓰는 법  로드 -> 자판을 떠났다가 **다시 들어가고** -> Stop
-- 산출물   C:/snatcher/dump/gaudi_batstream_v050_log.txt
--          C:/snatcher/dump/gaudi_batstream_v050_<포인터>.bin

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local BASE = "C:/snatcher/dump/gaudi_batstream_v050"
local ENTRY = 0x6DA0
local ZP = 0x2000
local GRAB = 1024
local MAX = 60

local seen, count, log = {}, 0, {}

local function rb(at) return emu.read(at, MEM) or 0 end
local function say(m) log[#log + 1] = m; emu.log(m) end
local function st()
  local ok, s = pcall(emu.getState)
  return (ok and s) or {}
end

emu.addMemoryCallback(function()
  if count >= MAX then return end
  local s = st()
  local p = rb(ZP + 0) | (rb(ZP + 1) << 8)
  local key = string.format("%04X", p)
  if seen[key] then return end
  seen[key] = true
  count = count + 1

  local mpr = {}
  for i = 0, 7 do mpr[#mpr + 1] = string.format("$%02X", (s["memoryManager.mpr[" .. i .. "]"] or -1) % 256) end
  say(string.format("스트림 #%d  P=$%04X  속성$04=$%02X  $03=$%02X  Y=%d  MPR %s",
    count, p, rb(ZP + 4), rb(ZP + 3), (s["cpu.y"] or -1) % 256, table.concat(mpr, " ")))

  if p >= 0x2000 and p < 0xFF00 then
    local t = {}
    local n = math.min(GRAB, 0x10000 - p)
    for i = 0, n - 1 do t[i + 1] = string.char(rb(p + i)) end
    local f = assert(io.open(BASE .. "_" .. key .. ".bin", "wb"))
    f:write(table.concat(t)); f:close()
    local head = {}
    for i = 0, 23 do head[#head + 1] = string.format("%02X", rb(p + i)) end
    say("      앞 24 B  " .. table.concat(head, " "))
  end
end, emu.callbackType.exec, ENTRY, ENTRY, CPU, MEM)

emu.addEventCallback(function()
  local f = assert(io.open(BASE .. "_log.txt", "w"))
  if #log == 0 then f:write("$6DA0 가 한 번도 안 불렸다 -- 자판을 떠났다가 다시 들어가야 한다\n") end
  for _, m in ipairs(log) do f:write(m .. "\n") end
  f:close()
  emu.log(string.format("GAUDI BAT STREAM 0.5.0 -> %s_log.txt  (서로 다른 스트림 %d 개)", BASE, count))
end, emu.eventType.scriptEnded)

emu.log("PROBE GAUDI BAT STREAM 0.5.0 loaded -- 자판 떠났다가 다시 들어가고 Stop")
