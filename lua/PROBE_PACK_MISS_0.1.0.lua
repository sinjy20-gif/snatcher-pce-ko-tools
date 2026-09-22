-- PROBE 팩 미스 0.1.0 -- 재생 중 CD 를 다시 읽는 이유를 잡는다
--
-- 왜
-- ---------------------------------------------------------------------------
-- PROBE_BOOT_LOAD 실측 (2026-08-22, 세 판을 같은 조건에서):
--
--     원본        58.3초  20회 371섹터   <- 여기서 끝.  더 안 읽는다
--     0.4.5.5     66.7초  88회 643섹터   (+68회)
--     0.4.5.6     99회 684섹터           (+79회)
--
-- 부팅까지는 셋이 **섹터 단위까지 동일**하고, 첫 대사 뒤부터 우리 판만 CD 를
-- 계속 읽는다.  읽을 때마다 드라이브가 시크하고, 시크하면 CD-DA 가 끊긴다.
-- 소유자가 "원본은 음악이 안 끊긴다" 고 한 것이 이 차이다.
--
-- 이상한 것은 `all` 로 전부 선적재한 0.4.5.5 도 68회를 읽는다는 점이다.
-- 선적재가 됐다면 레코드는 AC 에서 나와야 하고 CD 를 볼 일이 없다.  빌더 주석이
-- 말한 폴백이 도는 것으로 보인다:
--
--     "load_package / load_blob stay in the helper.  They simply stop firing,
--      and remain as the fallback if a pack ever is not resident."
--
-- 그 폴백이 정말 도는지, 돈다면 얼마나 도는지를 센다.
--
-- 어디를 보나 -- 헬퍼 심볼 그대로
-- ---------------------------------------------------------------------------
--     lookup        $BD74   레코드 조회 진입
--     pack_loaded   $BE14   팩이 이미 올라와 있다 (AC 에서 꺼냄 = 정상)
--     load_package  $BDCE   팩을 CD 에서 읽는다
--     load_blob     $BE79   ★ 폴백.  이게 돌면 팩이 제 일을 못 하는 것
--     return_miss   $BE6A   레코드 없음
--     copy_record   $BE23   AC -> RAM 복사
--     bios_cd_read  $E009   BIOS CD 읽기 (대조용)
--
-- 주소는 `build/patch/<판>/helper_symbols.json` 에서 온다.  판이 바뀌면 아래
-- 표만 갈아끼우면 된다 -- 하드코딩한 주소를 믿지 말 것.
--
-- 읽는 법
-- ---------------------------------------------------------------------------
--   load_blob 이 0 이면 폴백은 무죄고, CD 읽기는 load_package 가 하는 것이다
--     -> 팩이 선적재가 안 된 것.  preload 경로를 봐야 한다
--   load_blob 이 크면 조회가 팩에서 레코드를 못 찾고 있는 것이다
--     -> 팩 배정(classify)이나 상태 라우팅 문제
--
--   Script -> Settings -> Restrictions -> Allow I/O and OS

local mem = emu.memType.pceMemory

local stamp = "session"
if os ~= nil and os.date ~= nil then stamp = os.date("%Y%m%d_%H%M%S") end
local OUT = "C:\\snatcher\\dump\\probe_pack_miss_" .. stamp .. ".tsv"

-- helper_symbols.json (0.4.5.6-unpatched) 그대로
local POINTS = {
  { name = "lookup",       addr = 0xBD74 },
  { name = "pack_loaded",  addr = 0xBE14 },
  { name = "load_package", addr = 0xBDCE },
  { name = "load_blob",    addr = 0xBE79 },
  { name = "return_miss",  addr = 0xBE6A },
  { name = "copy_record",  addr = 0xBE23 },
  { name = "bios_cd_read", addr = 0xE009 },
}

local count, firstFrame = {}, {}
local frame, lastLog = 0, 0
local order = {}

for _, p in ipairs(POINTS) do
  count[p.name] = 0
  order[#order + 1] = p.name
  emu.addMemoryCallback(function()
    count[p.name] = count[p.name] + 1
    if firstFrame[p.name] == nil then firstFrame[p.name] = frame end
  end, emu.callbackType.exec, p.addr, p.addr, emu.cpuType.pce, mem)
end

local function line()
  local parts = {}
  for _, n in ipairs(order) do parts[#parts + 1] = string.format("%s %d", n, count[n]) end
  return table.concat(parts, " · ")
end

emu.addEventCallback(function()
  frame = frame + 1
  if frame - lastLog >= 900 then
    lastLog = frame
    emu.log(string.format("%5.1f초  %s", frame / 60, line()))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  local file = io.open(OUT, "w")
  if file ~= nil then
    file:write("point\taddr\tcount\tfirst_frame\n")
    for _, p in ipairs(POINTS) do
      file:write(string.format("%s\t%04X\t%d\t%s\n", p.name, p.addr, count[p.name],
        firstFrame[p.name] and tostring(firstFrame[p.name]) or ""))
    end
    file:close()
  end
  emu.log(string.format("%d 프레임 (%.1f초)  %s", frame, frame / 60, line()))
  emu.log("  -> " .. OUT)
  if count["load_blob"] > 0 then
    emu.log("  ★ load_blob 이 돌았다 -- 조회가 팩에서 레코드를 못 찾고 CD 폴백을 탄다")
  elseif count["load_package"] > 0 then
    emu.log("  ★ load_package 가 돌았다 -- 팩이 선적재되지 않아 재생 중 CD 에서 읽는다")
  else
    emu.log("  팩 경로는 CD 를 안 읽었다 -- 읽기의 출처는 게임 쪽이다")
  end
end, emu.eventType.scriptEnded)

emu.log("PROBE 팩 미스 0.1.0 -- 대사 몇 개 지나가고 Stop 하면 된다")
emu.log("  -> " .. OUT)
