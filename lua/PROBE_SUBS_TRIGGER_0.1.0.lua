-- PROBE 자막 트리거 0.1.0 -- title_cache_wipe 스텁이 오프닝 전에 도는가
--
-- 무엇을 묻나
-- ---------------------------------------------------------------------------
-- 자막 POC 의 마지막 미지수는 **로더를 어디서 부르느냐** 하나다.
-- 유력 후보는 `title_cache_wipe` 스텁이다.  이미 패치 경로가 있고
-- (`patch_title_cache_wipe.py` 가 씬 VM 핸들러 표 $7331 의 $73BD 를 스텁으로 돌린다),
-- 스텁 끝이 `JMP $73BD` 로 체인하는 구조라 우리가 하려는 것과 모양이 같다.
--
-- 다만 **타이틀에서 실제로 도는지, 오프닝보다 먼저 도는지 확인한 적이 없다.**
-- 추측으로 배선하면 안 되는 자리다.
--
--     스텁 걸림  ?     -> 안 돌면 다른 트리거를 찾아야 한다
--     CD_PLAY 보다 먼저?  -> 늦으면 자막이 첫 컷신을 놓친다
--     몇 번 도나 ?     -> 여러 번이면 로더의 "한 번만" 판정이 실제로 쓰인다
--
-- 주소
-- ---------------------------------------------------------------------------
--     $BCEF   스텁.  케이브를 $A000 창 이름으로 부를 때의 값
--     $7CEF   같은 바이트.  **타이틀 스폰 때 MPR3=$69 라 $6000 창에 온다**
--     $73BD   씬 VM 의 원래 스폰 핸들러.  스텁이 끝에서 체인하는 곳
--     $E012   CD_PLAY.  오프닝 t0
--
-- $7CEF 는 MPR3 가 $69 일 때만 스텁이다.  다른 뱅크가 걸려 있으면 전혀 다른 코드가
-- 그 자리에 있으므로 **MPR3 를 같이 찍어서 걸러야 한다.**  (0.1.0 계열이 뱅크를
-- 안 보고 헛돈 적이 있다 -- CD 드라이버를 $C000 으로 본 것이 그것이다.)
--
-- 돌리는 법
-- ---------------------------------------------------------------------------
--   **패치된 디스크로 돌릴 것.**  `patch_title_cache_wipe.py` 를 거치지 않은
--   `-unpatched` 폴더에는 스텁이 안 걸려 있어 당연히 0 건이 나온다.
--     build/patch/EXPERIMENT/0.3.12-bios/...cue
--   타이틀에서 오프닝이 끝까지 돌게 두고 Stop.

local OUT = "C:\\snatcher\\dump\\probe_subs_trigger_0_1_0.tsv"
local mem = emu.memType.pceMemory

local STUB    = 0x7CEF      -- title_cache_wipe (MPR3=$69 일 때)
local SPAWN   = 0x73BD      -- 원래 스폰 핸들러
local CD_PLAY = 0xE012
local STUB_BANK = 0x69

local file = assert(io.open(OUT, "w"))
file:write("kind\tframe\tmpr3\tcount\tmpr\tnote\n")

local frame, rows = 0, 0
local stubHits, stubRight, spawnHits, playHits = 0, 0, 0, 0
local firstStub, firstPlay = nil, nil
local LOG_MAX = 12

local function st()
  local ok, s = pcall(emu.getState)
  if not ok then return nil end
  return s
end

local function mprOf(s)
  if s == nil then return "", -1 end
  local t, m3 = {}, -1
  for slot = 0, 7 do
    local v = s[string.format("memoryManager.mpr[%d]", slot)]
    if v == nil then v = s[string.format("mpr[%d]", slot)] end
    v = v or 0
    if slot == 3 then m3 = v end
    t[#t + 1] = string.format("%02X", v)
  end
  return table.concat(t, " "), m3
end

local function row(kind, m3, count, mpr, note)
  rows = rows + 1
  file:write(string.format("%s\t%d\t%s\t%s\t%s\t%s\n", kind, frame,
    m3 >= 0 and string.format("%02X", m3) or "", tostring(count or ""),
    mpr or "", note or ""))
end

emu.addMemoryCallback(function()
  local s = st(); local mpr, m3 = mprOf(s)
  stubHits = stubHits + 1
  if m3 == STUB_BANK then
    stubRight = stubRight + 1
    if firstStub == nil then firstStub = frame end
    if stubRight <= LOG_MAX then
      row("stub", m3, stubRight, mpr, "title_cache_wipe 스텁 (MPR3=$69 맞음)")
    end
  elseif stubHits - stubRight <= 4 then
    row("other", m3, stubHits - stubRight, mpr,
        "$7CEF 이지만 다른 뱅크 -- 스텁이 아니다")
  end
end, emu.callbackType.exec, STUB, STUB, emu.cpuType.pce, mem)

emu.addMemoryCallback(function()
  spawnHits = spawnHits + 1
  if spawnHits <= 4 then
    local s = st(); local mpr, m3 = mprOf(s)
    row("spawn", m3, spawnHits, mpr, "원래 스폰 핸들러 $73BD")
  end
end, emu.callbackType.exec, SPAWN, SPAWN, emu.cpuType.pce, mem)

emu.addMemoryCallback(function()
  playHits = playHits + 1
  if firstPlay == nil then firstPlay = frame end
  if playHits <= 4 then
    local s = st(); local mpr, m3 = mprOf(s)
    row("cdplay", m3, playHits, mpr, "CD_PLAY -- 오프닝 t0")
  end
end, emu.callbackType.exec, CD_PLAY, CD_PLAY, emu.cpuType.pce, mem)

emu.addEventCallback(function() frame = frame + 1 end, emu.eventType.endFrame)

emu.addEventCallback(function()
  local verdict
  if stubRight == 0 then
    verdict = "★ 스텁이 한 번도 안 돌았다 -- 다른 트리거를 찾아야 한다 (패치본이 맞는지도 확인)"
  elseif firstPlay == nil then
    verdict = "스텁은 돌았으나 CD_PLAY 를 못 봤다 -- 오프닝을 끝까지 안 봤다"
  elseif firstStub < firstPlay then
    verdict = string.format(
      "★ 쓸 수 있다.  스텁이 프레임 %d, CD_PLAY 가 프레임 %d -- %d 프레임 먼저 돈다",
      firstStub, firstPlay, firstPlay - firstStub)
  else
    verdict = string.format(
      "★ 늦다.  스텁 프레임 %d > CD_PLAY 프레임 %d -- 첫 컷신을 놓친다",
      firstStub, firstPlay)
  end
  row("verdict", -1, "", "", verdict)
  file:write(string.format(
    "-- 프레임 %d · 스텁(맞는뱅크) %d / 전체적중 %d · 스폰 %d · CD_PLAY %d · 총 %d 행\n",
    frame, stubRight, stubHits, spawnHits, playHits, rows))
  file:close()
end, emu.eventType.scriptEnded)

emu.log("PROBE 자막 트리거 0.1.0 -- title_cache_wipe 가 오프닝 전에 도는가")
emu.log("  ★ 패치된 디스크로 돌릴 것.  -unpatched 에는 스텁이 없다")
emu.log("     build/patch/EXPERIMENT/0.3.12-bios/...cue")
emu.log("  verdict 행이 답이다.  오프닝 끝까지 두고 Stop")
emu.log("  출력: " .. OUT)
