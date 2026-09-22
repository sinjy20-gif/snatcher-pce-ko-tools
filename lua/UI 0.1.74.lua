-- UI 0.1.74 : Arcade Card 포트 쓰기 POC 판독
--
-- 무엇을 확인하는가
--   희소 디렉터리 설계는 지금까지 한 번도 안 써본 두 가지를 필요로 한다.
--     1. AC 데이터 포트로 **연속 쓰기** (자동증분).
--        지금까지는 포트로 읽기만 했고, 쓰기는 BIOS 가 뱅크 $40 창에 했다.
--     2. $1A10 의 **두 번째 포트**.
--        스캐터가 목록을 읽으면서 동시에 디렉터리를 써야 하는데,
--        포트가 하나뿐이면 항목마다 주소를 두 번 바꿔야 한다.
--
--   ac_0.1.17-portpoc 는 디렉터리 초기화 직후 한 번만 이렇게 한다.
--     포트0 -> AC $180000   $1A00 에 0,1,2 ... 15 를 연속 저장
--     포트1 -> AC $180200   $1A10 에 0,1,2 ... 15 를 연속 저장
--   두 목적지 모두 어떤 팩도 안 쓰는 영역이라 실패해도 게임 데이터를 안 건드린다.
--
-- 사용법
--   build/patch/ac_0.1.17-portpoc 의 CUE 로 실행. 파워 사이클.
--   접수처까지 가서 **한글이 한 줄이라도 나오면** 초기화가 끝난 것이다.
--   그때부터 이 스크립트가 자동으로 판독한다.
--
-- 판정
--   둘 다 성공   설계대로 희소 디렉터리 진행 가능
--   포트0 만     가능하지만 스캐터가 항목마다 주소를 두 번 바꿔야 함 (코드 +15B)
--   둘 다 실패   포트 쓰기가 자동증분을 안 한다 -> 2바이트 엔트리(32KB)로 후퇴

local PORT0_AC = 0x180000
local PORT1_AC = 0x180200
local LENGTH = 16

local ac = nil
for name, value in pairs(emu.memType or {}) do
  if string.lower(name) == "pcearcadecardram" then ac = value end
end

local frames = 0
local done = false
local firstSeen = nil

local function readRun(base)
  local out = {}
  for i = 0, LENGTH - 1 do
    out[i] = emu.read(base + i, ac)
  end
  return out
end

local function describe(run)
  local hex = {}
  for i = 0, LENGTH - 1 do
    hex[#hex + 1] = string.format("%02X", run[i] or 0)
  end
  return table.concat(hex, " ")
end

local function matches(run)
  for i = 0, LENGTH - 1 do
    if run[i] ~= i then return false end
  end
  return true
end

local function report(p0, p1, ok0, ok1)
  local L = {}
  local function W(s) L[#L + 1] = s end
  W("=== UI 0.1.74  AC 포트 쓰기 POC ===")
  W(string.format("프레임 %d 에서 판독", frames))
  W("")
  W(string.format("포트0 ($1A00) -> AC $%06X", PORT0_AC))
  W("  " .. describe(p0))
  W(string.format("  기대 00 01 02 ... %02X      %s", LENGTH - 1, ok0 and "O 일치" or "X 불일치"))
  W("")
  W(string.format("포트1 ($1A10) -> AC $%06X", PORT1_AC))
  W("  " .. describe(p1))
  W(string.format("  기대 00 01 02 ... %02X      %s", LENGTH - 1, ok1 and "O 일치" or "X 불일치"))
  W("")
  W("=== 판정 ===")
  if ok0 and ok1 then
    W("🟢 둘 다 성공.")
    W("   AC 포트 쓰기가 자동증분하고, 두 번째 포트도 독립적으로 동작한다.")
    W("   -> 희소 디렉터리를 설계대로 진행할 수 있다 (64KB -> 6,278B, 약 -1.7초)")
  elseif ok0 then
    W("🟡 포트0 만 성공.")
    W("   연속 쓰기는 되지만 $1A10 은 독립 포트가 아니다.")
    W("   -> 스캐터가 항목마다 주소를 두 번 바꿔야 한다 (코드 +15B, 시간은 무시할 수준)")
    W("      여전히 진행 가능하다.")
  elseif ok1 then
    W("🟡 포트1 만 성공. 예상 밖이다. 포트 번호 배치를 다시 봐야 한다.")
  else
    W("🔴 둘 다 실패.")
    W("   포트 쓰기가 자동증분을 안 하거나 쓰기 자체가 안 된다.")
    W("   -> 희소 디렉터리 폐기. 2바이트 엔트리(64KB -> 32KB, 약 -0.9초) 로 후퇴")
  end
  W("")
  W("주의: 이 빌드는 검증용 일회성이다. 배포 후보가 아니다.")
  W("      정상 동작 확인된 빌드는 ac_0.1.14 다.")

  emu.log("")
  emu.log("### 아래를 그대로 복사하세요 ###")
  for _, x in ipairs(L) do emu.log(x) end
  emu.log("### 여기까지 ###")
end

local function onFrame()
  frames = frames + 1
  if done or ac == nil then return end
  if frames % 30 ~= 0 then return end

  local p0 = readRun(PORT0_AC)
  local p1 = readRun(PORT1_AC)
  local ok0, ok1 = matches(p0), matches(p1)

  -- 초기화 전에는 둘 다 전원투입 난수다. 하나라도 맞으면 POC 가 돈 것이다.
  if ok0 or ok1 then
    if firstSeen == nil then
      firstSeen = frames
      return          -- 한 프레임 더 두고 안정된 값으로 판독
    end
    done = true
    report(p0, p1, ok0, ok1)
  end
end

emu.addEventCallback(onFrame, emu.eventType.endFrame)

if ac == nil then
  emu.log("🔴 pceArcadeCardRam memType 을 못 찾았습니다")
  emu.log("   Settings -> PC Engine -> CD-ROM System 이 Arcade CD-ROM² 인지 확인")
else
  emu.log("UI 0.1.74 loaded - AC 포트 쓰기 POC 판독")
  emu.log(string.format("  포트0 -> AC $%06X / 포트1 -> AC $%06X", PORT0_AC, PORT1_AC))
  emu.log("  접수처에서 한글이 한 줄이라도 나오면 자동으로 판독합니다")
  emu.log("  (디렉터리 초기화 시점에 POC 가 한 번 실행됩니다)")
end
