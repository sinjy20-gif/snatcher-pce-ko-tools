-- PROBE 프리로더 0.1.0 -- 레코드는 실렸는데 왜 일본어가 나가는가
--
-- 어디까지 왔나 (2026-08-18 밤, 실측)
-- ---------------------------------------------------------------------------
--   PROBE_FONT_ADDR_0.1.6   EX_GETFNT 202 회 · 한글코드 0 회 · 82/83(가나) 111 회
--                           -> 폰트가 아니다.  렌더러가 일본어를 그리고 있다
--   PROBE_RECORD_PATH_0.1.0 init_store -> init_ok · lookup -> valid -> copy_record
--                           -> **레코드는 정상으로 캐시에 실린다** (pack 00/01/02)
--
-- 두 관측은 모순이 아니다.  copy_record 는 "AC 에서 캐시로 실었다" 까지고,
-- 그것을 **렌더러가 받아들일지**는 프리로더의 서명 검사가 따로 정한다.
-- 검사에서 떨어지면 $03/$04 가 원문을 계속 가리켜 일본어가 그대로 나간다.
--
-- 프리로더 흐름 (build_direct_overlay_patch_ui.py:142~, 디스크 바이트와 일치 확인)
-- ---------------------------------------------------------------------------
--     $5E40  진입 ($66E5 훅)
--     $5E7B  pointer_ok        원문 포인터가 $3619 / $3499 / $349A -- 조회 대상
--     $5E78  reject_pointer    그 외 -> 손 안 댄다 (정상)
--     $5F20  probe_slot        해시 -> 섹터.  최대 4 회 (probes=4 실측)
--     $5F3B  slot_loaded       섹터 적재 성공.  캐시 $5B80 에 레코드가 있다
--     $5F45  signature_start   ★ 여기부터 서명 대조
--                                $5B88/$5B89 == STATE_LO/HI
--                                $5B85/$5B86/$5B87 == 원문 길이/XOR/누산
--     $5F72  signature_checks_ok  ★★ 통과.  $03/$04 를 캐시 텍스트로 돌린다
--     $5F97  probe_mismatch    서명 불일치 -> 다음 프로브
--     $5FB4  search_failed     4 회 다 실패 -> 일본어
--     $5FCC  no_match          해시 루프 실패 (원문 64 B 초과 등)
--
-- 갈래
-- ---------------------------------------------------------------------------
--   pointer_ok 0            훅은 도는데 게이트가 다 거부한다 -> 원문 포인터 형태가 다르다
--   slot_loaded 0           섹터 적재가 안 된다 -> 로더/AC
--   checks_ok 0, mismatch 多 ★ 서명이 안 맞는다.  아래 cmp 행의 어느 항이 틀렸는지 본다
--   checks_ok 있는데 일본어  받아들이고도 안 나온 것 -> 그 다음(캐시 텍스트 내용)
--
-- 돌리는 법
-- ---------------------------------------------------------------------------
--   디스크  build\patch\0.4.1-bios\...[KO 0.3.12-bios] (0818-2000).cue
--   부팅 후 접수처 대사 + 액션 메뉴까지.  스크립트를 멈추면 summary 가 붙는다.
--   출력: C:\snatcher\dump\probe_preloader_0_1_0.tsv

local OUT = "C:\\snatcher\\dump\\probe_preloader_0_1_0.tsv"
local mem = emu.memType.pceMemory

local ENTRY      = 0x5E40
local POINTER_OK = 0x5E7B
local REJECT     = 0x5E78
local PROBE_SLOT = 0x5F20
local SLOT_LOADED= 0x5F3B
local SIG_START  = 0x5F45
local CHECKS_OK  = 0x5F72
local MISMATCH   = 0x5F97
local SEARCH_FAIL= 0x5FB4
local NO_MATCH   = 0x5FCC

local CACHE = 0x5B80
local PRIV  = 0x7FEC
local STATE_LO, STATE_HI = PRIV + 0, PRIV + 1
local SECTOR_LO, SECTOR_MID = PRIV + 3, PRIV + 4
local SOURCE_LEN, SIG_XOR, SIG_CUM = PRIV + 7, PRIV + 8, PRIV + 9
local PROBE_NO = PRIV + 15

local LOG_MAX = 50

local file = assert(io.open(OUT, "w"))
file:write("kind\tframe\tsrcptr\tsource\tsector\tprobe\tcmp\tnote\n")

local frame, dirty, logged = 0, false, 0
local n = { entry = 0, ok = 0, reject = 0, probe = 0, loaded = 0, sig = 0,
            checks = 0, mismatch = 0, failed = 0, nomatch = 0 }
local lastPtr = 0

local function byte(a) return emu.read(a, mem) or 0 end
local function word(a) return byte(a) + byte(a + 1) * 256 end

local function srcBytes(p, count)
  local out = {}
  for k = 0, count - 1 do
    local v = byte(p + k)
    out[#out + 1] = string.format("%02X", v)
    if v == 0xFF then break end
  end
  return table.concat(out, " ")
end

local function row(kind, ptr, source, sector, probe, cmp, note)
  file:write(string.format("%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\n",
    kind, frame,
    ptr and string.format("%04X", ptr) or "",
    source or "",
    sector and string.format("%04X", sector) or "",
    probe or "", cmp or "", note or ""))
  dirty = true
end

local function hook(addr, fn)
  emu.addMemoryCallback(fn, emu.callbackType.exec, addr, addr, emu.cpuType.pce, mem)
end

hook(ENTRY, function() n.entry = n.entry + 1 end)
hook(REJECT, function() n.reject = n.reject + 1 end)

hook(POINTER_OK, function()
  n.ok = n.ok + 1
  lastPtr = word(0x2003)                    -- ZP $03/$04 = 원문 포인터
  if n.ok <= 5 then
    row("pointer_ok", lastPtr, srcBytes(lastPtr, 16), nil, nil, nil,
      "조회 대상으로 받았다")
  end
end)

hook(PROBE_SLOT, function() n.probe = n.probe + 1 end)

hook(SLOT_LOADED, function()
  n.loaded = n.loaded + 1
  if n.loaded <= 5 then
    row("slot_loaded", lastPtr, nil, word(SECTOR_LO), byte(PROBE_NO), nil,
      string.format("캐시 매직 %02X %02X %02X %02X",
        byte(CACHE), byte(CACHE + 1), byte(CACHE + 2), byte(CACHE + 3)))
  end
end)

-- ★ 핵심.  서명 대조 직전에 양쪽 값을 그대로 남긴다
hook(SIG_START, function()
  n.sig = n.sig + 1
  if logged >= LOG_MAX then return end
  logged = logged + 1
  local pairs_ = {
    { "state_lo", CACHE + 8, STATE_LO },
    { "state_hi", CACHE + 9, STATE_HI },
    { "src_len",  CACHE + 5, SOURCE_LEN },
    { "sig_xor",  CACHE + 6, SIG_XOR },
    { "sig_cum",  CACHE + 7, SIG_CUM },
  }
  local parts, bad = {}, {}
  for _, p in ipairs(pairs_) do
    local a, b = byte(p[2]), byte(p[3])
    parts[#parts + 1] = string.format("%s %02X/%02X", p[1], a, b)
    if a ~= b then bad[#bad + 1] = p[1] end
  end
  row("cmp", lastPtr, srcBytes(lastPtr, 12), word(SECTOR_LO), byte(PROBE_NO),
    (#bad == 0) and "ALL OK" or ("불일치: " .. table.concat(bad, ",")),
    "레코드/실측 -- " .. table.concat(parts, " · "))
end)

hook(CHECKS_OK, function() n.checks = n.checks + 1 end)
hook(MISMATCH, function() n.mismatch = n.mismatch + 1 end)
hook(SEARCH_FAIL, function()
  n.failed = n.failed + 1
  if n.failed <= 5 then
    row("search_failed", lastPtr, srcBytes(lastPtr, 12), word(SECTOR_LO),
      byte(PROBE_NO), nil, "프로브 4 회 소진 -> 일본어 원문")
  end
end)
hook(NO_MATCH, function() n.nomatch = n.nomatch + 1 end)

emu.addEventCallback(function()
  frame = frame + 1
  if dirty then file:flush() dirty = false end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  row("summary", nil, nil, nil, nil, nil, string.format(
    "훅 %d · pointer_ok %d · reject %d · probe %d · slot_loaded %d · sig %d · CHECKS_OK %d · mismatch %d · search_failed %d · no_match %d",
    n.entry, n.ok, n.reject, n.probe, n.loaded, n.sig, n.checks,
    n.mismatch, n.failed, n.nomatch))
  if n.ok == 0 then
    file:write("-- 게이트가 전부 거부.  원문 포인터가 $3619/$3499/$349A 가 아니다\n")
  elseif n.loaded == 0 then
    file:write("-- 섹터 적재가 안 된다.  로더/AC 쪽\n")
  elseif n.checks == 0 then
    file:write("-- ★ 서명 검사에서 전부 떨어진다.  cmp 행의 불일치 항이 원인이다\n")
  else
    file:write("-- 받아들인 것이 있다.  그런데도 일본어면 캐시 텍스트 내용을 볼 것\n")
  end
  file:close()
end, emu.eventType.scriptEnded)

emu.log("PROBE 프리로더 0.1.0 -- 레코드는 실렸는데 왜 일본어가 나가는가")
emu.log("  ★ cmp 행을 볼 것.  레코드값/실측값 이 어긋난 항이 범인이다")
emu.log("  출력: " .. OUT)
