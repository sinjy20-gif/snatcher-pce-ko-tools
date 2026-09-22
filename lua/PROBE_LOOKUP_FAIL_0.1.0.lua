-- PROBE 조회실패 0.1.0 -- 프리로더가 죽기 직전 **어느 경로**로 갔는지 찍는다
--
-- 여기까지 (2026-08-19, 조이 디비전 쇼핑하기 진행불가)
-- ---------------------------------------------------------------------------
--   우리 것 확정      원본 디스크는 정상
--   BIOS 무관         JP 원본 BIOS 로도 죽는다
--   오늘 작업 무관     0.3.9(BIOS 이전)도 죽는다
--   벽 무관           벽을 안 눌러도 죽는다 -> 조건부 UI 확장 가설 기각
--   $2200 무관        JMP($2200) 은 0 회.  벡터 오염은 폭주의 결과였다
--   사망 형태         I/O 페이지 실행 -> BRK 무한루프 (HuC6280 은 BRK 가 IRQ2 벡터)
--                     폭주 직전 IRQ2 가 명령어마다 터진다 (푸시 417 만 회)
--
-- 남은 유력 가설
-- ---------------------------------------------------------------------------
-- 구매 목록의 두 항목(`文` · `やさしき`)이 **우리 코퍼스 어디에도 없다**
-- (ui_text · 마스터 · legacy 전부 0 건).  그러면 그 문자열들은 반드시
-- **조회 실패 경로**를 탄다.  그 경로에는 이런 주석이 붙어 있다:
--
--     A failed open-addressing lookup still overwrites $5B80-$5E3F,
--     including the live Korean font cache.
--
-- 게다가 이 상점의 항목들은 해시 충돌로 슬롯이 밀려 있다 (실측):
--     壁 3E8D->3E8F(2칸) · 店員 1901->1904(3칸) · マスク 3E57->3E58(1칸)
-- 프로브 상한은 4 다.  실패·재프로브가 잦은 화면이라는 뜻이다.
--
-- 무엇을 찍나 -- 프리로더의 갈래 전부
-- ---------------------------------------------------------------------------
--   $5E7B pointer_ok        조회 대상으로 받음
--   $5E78 reject_pointer    게이트에서 거부 (정상.  손 안 댐)
--   $5F20 probe_slot        프로브 시작/재시도
--   $5F3B slot_loaded       섹터 적재 성공
--   $5F45 signature_start   서명 대조 시작
--   $5F72 checks_ok         ★ 통과 -- 번역이 나간다
--   $5F97 probe_mismatch    서명 불일치 -> 다음 프로브
--   $5FB4 search_failed     ★ 4 회 소진 -- 여기가 의심 경로다
--   $5FCC no_match          해시 루프 실패
--   $5FE6 done              빠져나감
--
-- 폭주(I/O 페이지 실행) 순간에 직전 80 건을 쏟는다.
--
-- 돌리는 법
-- ---------------------------------------------------------------------------
--   조이 디비전 -> 쇼핑하기.  멈추면 파일이 이미 생겨 있다.
--   출력: C:\snatcher\dump\probe_lookup_fail_0_1_0.tsv

local OUT = "C:\\snatcher\\dump\\probe_lookup_fail_0_1_0.tsv"
local mem = emu.memType.pceMemory

local SITES = {
  { 0x5E78, "reject" }, { 0x5E7B, "ptr_ok" }, { 0x5F20, "probe" },
  { 0x5F3B, "loaded" }, { 0x5F45, "sig" },    { 0x5F72, "OK★" },
  { 0x5F97, "mismatch" }, { 0x5FB4, "FAILED★" }, { 0x5FCC, "no_match" },
  { 0x5FE6, "done" },
}

local PRIV = 0x7FEC
local SECTOR_LO = PRIV + 3
local PROBE_NO  = PRIV + 15
local CACHE = 0x5B80
local ZP = 0x2000

local RING, BOOT_GRACE = 80, 180
local ring, ringPos, total = {}, 0, 0
local frame, fired = 0, false
local tally = {}

local function byte(a) return emu.read(a, mem) or 0 end
local function word(a) return byte(a) + byte(a + 1) * 256 end

local function push(tag)
  ringPos = ringPos % RING + 1
  total = total + 1
  tally[tag] = (tally[tag] or 0) + 1
  local e = ring[ringPos]
  if e == nil then e = {}; ring[ringPos] = e end
  e.n, e.frame, e.tag = total, frame, tag
  e.sector = word(SECTOR_LO)
  e.probe = byte(PROBE_NO)
  e.src = word(ZP + 3)
  e.magic = byte(CACHE)
end

for _, s in ipairs(SITES) do
  emu.addMemoryCallback(function() push(s[2]) end,
    emu.callbackType.exec, s[1], s[1], emu.cpuType.pce, mem)
end

local function dump(reason)
  if fired then return end
  fired = true
  local file = io.open(OUT, "w")
  if file == nil then return end
  file:write("-- 조회실패 0.1.0 · 사유: " .. reason .. "\n")
  file:write(string.format("-- 프레임 %d · 총 통과 %d\n", frame, total))
  local ok, s = pcall(emu.getState)
  if ok and s then
    file:write(string.format("-- 폭주 PC $%04X · SP $%02X\n", s["cpu.pc"] or 0, s["cpu.sp"] or 0))
  end
  local t = {}
  for k, v in pairs(tally) do t[#t + 1] = string.format("%s %d", k, v) end
  table.sort(t)
  file:write("-- 경로별 횟수: " .. table.concat(t, " · ") .. "\n\n")
  file:write("n\tframe\ttag\tsector\tprobe\tsrcptr\tcache첫바이트\n")
  for i = 1, RING do
    local e = ring[(ringPos + i - 1) % RING + 1]
    if e and e.n then
      file:write(string.format("%d\t%d\t%s\t%04X\t%02X\t%04X\t%02X\n",
        e.n, e.frame, e.tag, e.sector, e.probe, e.src, e.magic))
    end
  end
  file:close()
  emu.log("★ 조회실패 덤프 (" .. reason .. ") -> " .. OUT)
end

emu.addMemoryCallback(function()
  if frame > BOOT_GRACE then dump("폭주 -- I/O 페이지 실행") end
end, emu.callbackType.exec, 0x0000, 0x1FFF, emu.cpuType.pce, mem)

local DUMP_KEYS = { "E", "e", "KeyE", "D", "Q", "R" }
local dumpKey = nil
for _, name in ipairs(DUMP_KEYS) do
  local ok, v = pcall(function() return emu.isKeyPressed(name) end)
  if ok and type(v) == "boolean" then dumpKey = name break end
end

local held = false
emu.addEventCallback(function()
  frame = frame + 1
  if dumpKey then
    local ok, down = pcall(function() return emu.isKeyPressed(dumpKey) end)
    down = ok and down == true
    if down and not held then dump("수동 (" .. dumpKey .. ")") end
    held = down
  end
  emu.drawString(4, 4, string.format("조회경로 감시 · 통과 %d %s", total,
    fired and "· ★잡음" or ""), fired and 0xFF6060 or 0x80FF80, 0x80000000, 1)
  emu.drawString(4, 14, string.format("FAILED %d · OK %d · mismatch %d",
    tally["FAILED★"] or 0, tally["OK★"] or 0, tally["mismatch"] or 0),
    0xC0C0C0, 0x80000000, 1)
end, emu.eventType.endFrame)

emu.log("PROBE 조회실패 0.1.0 -- 프리로더의 갈래를 전부 찍는다")
emu.log("  FAILED★ 가 죽기 직전에 몰리면 조회 실패 경로가 범인이다")
emu.log("  출력: " .. OUT)
