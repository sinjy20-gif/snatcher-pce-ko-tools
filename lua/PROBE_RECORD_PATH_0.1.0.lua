-- PROBE 레코드경로 0.1.0 -- 번역 레코드 치환이 어디서 끊기는가
--
-- 왜 만드나
-- ---------------------------------------------------------------------------
-- 2026-08-18 20:43, PROBE_FONT_ADDR_0.1.6 이 0.4.1-bios 대사창에서 이렇게 나왔다.
--
--     EX_GETFNT 202 회 · 그중 한글코드 0 회
--     리드바이트 분포 -- 81:11 82:74 83:37 8C:11 8E:10 92:13 93:11 95:10 ...
--
-- 82(히라가나) 74 회 · 83(가타카나) 37 회.  **게임이 일본어 원문을 그리고 있다.**
-- 한글 코드는 BIOS 까지 오지도 않았다.  즉 폰트/배정표/글리프 문제가 아니라
-- **레코드 치환이 안 돈다.**  이 프로브는 그 앞단을 본다.
--
-- 대조로 이미 확인된 것 (다시 안 잰다)
-- ---------------------------------------------------------------------------
--     Track 02 는 0.3.11-bios-opt(한글이 나오던 판) 와 0.4.1 이 실질 동일하다.
--       차이는 2 단계 스텁 위치뿐 -- 정확히 한 섹터(2352 B) 어긋난 같은 구조다
--     Syscard3_galmuri.pce 는 JP 원본과 $031FDA-$038051 (폰트 데이터) 만 다르다.
--       BIOS 코드는 한 바이트도 안 바뀌었다 -> CD 읽기를 망칠 수 없다
--
-- 헬퍼 흐름 (build_ac_dynamic_0_1_14.py:789~)
-- ---------------------------------------------------------------------------
--     $BCD2  진입 -- AC 디렉터리 MAGIC 확인
--              불일치 -> init_store ($BD13) 로 CD 에서 적재
--              일치   -> lookup ($BD5F)
--     $BD5F  lookup   $7FEF/$7FF0 (원문 슬롯) -> AC 디렉터리 조회
--                     PACK_ID 가 $FF 면 return_miss -> **일본어 원문이 그대로 나간다**
--     $BDA8  valid_pack   PACK_ID 유효.  팩이 안 실렸으면 load_package
--     $BE0E  copy_record  여기까지 오면 번역이 화면으로 나간다
--     $BE55  return_miss  치환 없음
--     $BEF2  blob_failed  CD 적재 실패
--
-- 갈래
-- ---------------------------------------------------------------------------
--   (A) lookup 0 회            헬퍼가 아예 안 불린다 -> 스텁/핸들러표(2 단계) 문제
--   (B) lookup 있고 miss 100%  디렉터리에 그 슬롯이 없다 -> 팩/디렉터리 생성 문제
--   (C) miss 섞임              특정 팩만 안 온다 -> pack_id 분포와 blob_failed 를 볼 것
--   (D) copy_record 도는데 일본어  치환은 됐는데 딴 게 나간 것 -> 그 다음 단계
--
-- 돌리는 법
-- ---------------------------------------------------------------------------
--   디스크  build\patch\0.4.1-bios\...[KO 0.3.12-bios] (0818-2000).cue
--   ★ **파워 사이클(새로 부팅)하고 바로 켤 것.**  init_store 는 첫 한글 조회
--     때 한 번만 돌아서, 세이브스테이트로 들어가면 그 장면을 놓친다.
--   접수처 대사까지 진행한 뒤 스크립트를 멈추면 summary 가 붙는다.
--
--   출력: C:\snatcher\dump\probe_record_path_0_1_0.tsv

local OUT = "C:\\snatcher\\dump\\probe_record_path_0_1_0.tsv"
local mem = emu.memType.pceMemory

-- helper_symbols.json (build\patch\0.4.1-bios) 그대로
local HELPER      = 0xBCD2
local INIT_STORE  = 0xBD13
local INIT_OK     = 0xBD40
local LOOKUP      = 0xBD5F
local VALID_PACK  = 0xBDA8
local LOAD_PKG    = 0xBDB9
local PACK_LOADED = 0xBDFF
local COPY_RECORD = 0xBE0E
local RETURN_MISS = 0xBE55
local BLOB_FAILED = 0xBEF2
local TITLE_WIPE  = 0xBCEF

-- scratch = HELPER_LIMIT($C000) - $20.  변수 순서는 build_helper_compact 와 같다
local SCRATCH   = 0xBFE0
local STATUS    = SCRATCH + 7
local PACK_ID   = SCRATCH + 8
local REC_LO    = SCRATCH + 9
local REC_MID   = SCRATCH + 10
local REC_HI    = SCRATCH + 11

local SLOT_LO, SLOT_HI = 0x7FEF, 0x7FF0    -- lookup 이 읽는 원문 슬롯
local CACHE_BASE = 0x5B80                  -- copy_record 가 'SDR4' 를 남기는 자리

local LOG_MAX = 60

local file = assert(io.open(OUT, "w"))
file:write("kind\tframe\tslot\tpack\trec\tstatus\tnote\n")

local frame, dirty, logged = 0, false, 0
local n = { helper = 0, init = 0, initok = 0, lookup = 0, valid = 0,
            loadpkg = 0, pkgloaded = 0, copy = 0, miss = 0, blobfail = 0,
            titlewipe = 0 }
local packTally, missSlots = {}, {}
local lastSlot = 0

local function byte(a) return emu.read(a, mem) or 0 end
local function word(a) return byte(a) + byte(a + 1) * 256 end

local function row(kind, slot, pack, rec, status, note)
  file:write(string.format("%s\t%d\t%s\t%s\t%s\t%s\t%s\n",
    kind, frame,
    slot and string.format("%04X", slot) or "",
    pack and string.format("%02X", pack) or "",
    rec or "",
    status and string.format("%02X", status) or "",
    note or ""))
  dirty = true
end

local function hook(addr, fn)
  emu.addMemoryCallback(fn, emu.callbackType.exec, addr, addr, emu.cpuType.pce, mem)
end

hook(HELPER, function()
  n.helper = n.helper + 1
  if n.helper == 1 then
    row("helper", nil, nil, nil, nil, "헬퍼 첫 진입 ($BCD2).  스텁은 살아 있다")
  end
end)

hook(TITLE_WIPE, function() n.titlewipe = n.titlewipe + 1 end)

hook(INIT_STORE, function()
  n.init = n.init + 1
  if n.init <= 3 then
    row("init_store", nil, nil, nil, nil,
      "AC 디렉터리 MAGIC 불일치 -> CD 에서 적재 시작 (" .. n.init .. "회째)")
  end
end)

hook(INIT_OK, function()
  n.initok = n.initok + 1
  if n.initok <= 3 then row("init_ok", nil, nil, nil, nil, "적재 성공") end
end)

hook(LOOKUP, function()
  n.lookup = n.lookup + 1
  lastSlot = word(SLOT_LO)
  if n.lookup <= 3 then
    row("lookup", lastSlot, nil, nil, nil, "첫 조회들 -- 원문 슬롯 $7FEF/$7FF0")
  end
end)

hook(VALID_PACK, function()
  n.valid = n.valid + 1
  local pack = byte(PACK_ID)
  packTally[pack] = (packTally[pack] or 0) + 1
  if logged < LOG_MAX then
    logged = logged + 1
    row("valid", lastSlot, pack,
      string.format("%02X%02X%02X", byte(REC_HI), byte(REC_MID), byte(REC_LO)),
      byte(STATUS), "디렉터리 적중")
  end
end)

hook(LOAD_PKG, function() n.loadpkg = n.loadpkg + 1 end)
hook(PACK_LOADED, function() n.pkgloaded = n.pkgloaded + 1 end)

hook(COPY_RECORD, function()
  n.copy = n.copy + 1
  if n.copy <= 5 then
    row("copy_record", lastSlot, byte(PACK_ID),
      string.format("%02X%02X%02X", byte(REC_HI), byte(REC_MID), byte(REC_LO)),
      byte(STATUS), "번역이 화면으로 나가는 지점")
  end
end)

hook(RETURN_MISS, function()
  n.miss = n.miss + 1
  missSlots[lastSlot] = (missSlots[lastSlot] or 0) + 1
  if logged < LOG_MAX then
    logged = logged + 1
    row("miss", lastSlot, byte(PACK_ID), nil, byte(STATUS),
      "치환 없음 -> 일본어 원문이 그대로 나간다")
  end
end)

hook(BLOB_FAILED, function()
  n.blobfail = n.blobfail + 1
  if n.blobfail <= 5 then
    row("blob_failed", lastSlot, byte(PACK_ID), nil, byte(STATUS), "CD 적재 실패")
  end
end)

emu.addEventCallback(function()
  frame = frame + 1
  if dirty then file:flush() dirty = false end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  local packs = {}
  for pack, c in pairs(packTally) do
    packs[#packs + 1] = string.format("%02X:%d", pack, c)
  end
  table.sort(packs)

  local slots, kinds = {}, 0
  for slot, c in pairs(missSlots) do
    kinds = kinds + 1
    if #slots < 12 then slots[#slots + 1] = string.format("%04X x%d", slot, c) end
  end

  row("summary", nil, nil, nil, nil, string.format(
    "helper %d · init_store %d (성공 %d) · lookup %d · valid %d · load_pkg %d (완료 %d) · copy_record %d · miss %d · blob_failed %d · title_wipe %d",
    n.helper, n.init, n.initok, n.lookup, n.valid, n.loadpkg, n.pkgloaded,
    n.copy, n.miss, n.blobfail, n.titlewipe))
  row("packs", nil, nil, nil, nil, "적중 pack_id 분포 -- " ..
    (#packs > 0 and table.concat(packs, " ") or "(없음)"))
  row("misses", nil, nil, nil, nil, string.format(
    "miss 슬롯 %d 종 -- %s", kinds, table.concat(slots, " ")))
  row("cache", nil, nil, nil, nil, string.format(
    "$5B80 = %02X %02X %02X %02X  ('SDR4' = 53 44 52 34 면 copy_record 가 돈 적 있다)",
    byte(CACHE_BASE), byte(CACHE_BASE + 1), byte(CACHE_BASE + 2), byte(CACHE_BASE + 3)))

  if n.lookup == 0 then
    file:write("-- (A) 헬퍼 조회가 한 번도 안 불렸다.  2 단계 스텁/핸들러표를 볼 것\n")
  elseif n.copy == 0 then
    file:write("-- (B) 조회는 도는데 치환이 한 번도 안 됐다.  디렉터리/팩 생성을 볼 것\n")
  elseif n.miss > 0 then
    file:write("-- (C) 섞여 있다.  packs 분포와 miss 슬롯을 볼 것\n")
  else
    file:write("-- (D) 치환은 전부 돌았다.  그 다음 단계(레코드 내용/렌더)를 볼 것\n")
  end
  file:close()
end, emu.eventType.scriptEnded)

emu.log("PROBE 레코드경로 0.1.0 -- 번역 치환이 어디서 끊기는가")
emu.log("  ★ 파워 사이클하고 바로 켤 것.  init_store 는 첫 조회 때 한 번뿐이다")
emu.log("  lookup 0     -> 헬퍼가 안 불린다 (2 단계 스텁 문제)")
emu.log("  copy_record 0-> 조회는 되는데 전부 miss (디렉터리/팩 문제)")
emu.log("  출력: " .. OUT)
