-- PROBE CD읽기 0.1.0 -- 그 화면의 글자가 **디스크 어디서 오는가**
--
-- 왜 이걸 보나 (소유자 제안, 2026-08-19)
-- ---------------------------------------------------------------------------
-- 조이 디비전 "쇼핑하기" 목록의 문자열(`女` · `やさしき`)이 **어느 트랙에도
-- 원시 SJIS 로 없다** (24 트랙 전수 검색, 0 건).  압축돼 있거나 그림이다.
-- 그래서 우리 수집기가 못 봤고, 번역도 못 한다.
--
-- 그런데 지금 쫓는 버그가 하필 그 화면에서만 터진다 (다른 UI 는 안 죽는다).
-- 그러면 **그 화면이 읽어들이는 자리**와 우리가 바꾼 자리가 겹치는지가 핵심이다.
--
-- 이 프로브는 일본 원판에서 그 화면이 뜰 때 **어느 섹터를 읽는지** 기록한다.
-- 그 섹터 번호를 우리 빌드의 수정 구간과 대조하면 충돌 여부가 바로 나온다.
--
-- BIOS CD_READ 규약 (점프표 실측: $E009 -> $EC05)
-- ---------------------------------------------------------------------------
--   $F8      읽을 섹터 수
--   $F9      (상위)
--   $FA/$FB  목적지 주소 (하위/상위)
--   $FC      전송 모드
--   $FD/$FE  섹터 번호 (상위/하위) -- CD_BASE 로 정한 기준에서의 상대 섹터
--   $FF      목적지 뱅크/MPR
--
-- 호출자(스택의 복귀주소)도 같이 남긴다.  같은 화면이라도 누가 부르는지가
-- 갈리면 경로가 여럿이라는 뜻이다.
--
-- 돌리는 법
-- ---------------------------------------------------------------------------
--   ★ **일본 원판**으로 돌린다 (rom(japan)\...\Snatcher CD-ROMantic (Japan).cue)
--     BIOS 도 JP 원본이어야 한다.
--   상점 앞에서 켜고 -> 쇼핑하기 -> 목록이 뜨면 정지.
--   출력: C:\snatcher\dump\probe_cd_reads_0_1_0.tsv

local OUT = "C:\\snatcher\\dump\\probe_cd_reads_0_1_0.tsv"
local mem = emu.memType.pceMemory

local CD_READ = 0xE009      -- 점프표 항목 (여기로 JSR 한다)
local CD_BASE = 0xE006
local CD_SEEK = 0xE00C
local ZP = 0x2000
local STACK = 0x2100

local file = assert(io.open(OUT, "w"))
file:write("kind\tframe\tsector\tcount\tdest\tmode\tbank\tcaller\n")

local frame, reads, dirty = 0, 0, false

local function byte(a) return emu.read(a, mem) or 0 end

local function caller()
  local ok, s = pcall(emu.getState)
  if not ok or s == nil then return 0 end
  local sp = s["cpu.sp"] or 0
  local lo = byte(STACK + ((sp + 1) % 256))
  local hi = byte(STACK + ((sp + 2) % 256))
  return (hi * 256 + lo + 1) % 0x10000
end

local function log(kind)
  reads = reads + 1
  local sector = byte(ZP + 0xFD) * 256 + byte(ZP + 0xFE)
  file:write(string.format("%s\t%d\t%04X\t%02X\t%02X%02X\t%02X\t%02X\t%04X\n",
    kind, frame, sector, byte(ZP + 0xF8),
    byte(ZP + 0xFB), byte(ZP + 0xFA), byte(ZP + 0xFC), byte(ZP + 0xFF),
    caller()))
  dirty = true
end

emu.addMemoryCallback(function() log("READ") end,
  emu.callbackType.exec, CD_READ, CD_READ, emu.cpuType.pce, mem)
emu.addMemoryCallback(function() log("BASE") end,
  emu.callbackType.exec, CD_BASE, CD_BASE, emu.cpuType.pce, mem)
emu.addMemoryCallback(function() log("SEEK") end,
  emu.callbackType.exec, CD_SEEK, CD_SEEK, emu.cpuType.pce, mem)

emu.addEventCallback(function()
  frame = frame + 1
  if dirty then file:flush() dirty = false end
  emu.drawString(4, 4, string.format("CD 호출 %d 건", reads), 0x80FF80, 0x80000000, 1)
  emu.drawString(4, 14, "쇼핑하기 누르고 목록 뜨면 정지", 0xFFFF80, 0x80000000, 1)
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  file:write(string.format("\n-- CD 호출 총 %d 건 · 프레임 %d\n", reads, frame))
  file:write("-- sector 는 CD_BASE 가 정한 기준에서의 **상대** 섹터다.\n")
  file:write("--   직전 BASE 행의 값과 같이 봐야 절대 위치가 나온다.\n")
  file:close()
end, emu.eventType.scriptEnded)

emu.log("PROBE CD읽기 0.1.0 -- 그 화면이 어느 섹터를 읽는지 기록한다")
emu.log("  ★ 일본 원판으로 돌릴 것.  쇼핑하기 -> 목록 뜨면 정지")
emu.log("  출력: " .. OUT)
