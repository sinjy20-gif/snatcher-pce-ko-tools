-- GFX 0.1.1 -- 면책 화면의 타일이 **어디서 오는지** 잰다
--
-- ★ 순수 관측.  아무것도 안 쓰고 화면에도 안 그린다.
--
-- 0.1.0 에서 얻은 것 (dump/gfx_20260905_092608)
-- ---------------------------------------------
-- 화면은 복원했다.  BAT 폭 64 · 팔레트 0 · 글자 칸 행 6..19 · 열 2..28.
-- 타일 $110-$1F5 가 글자다.  플레인1 이 플레인0 의 **정확한 보수**라 2 색이고,
-- 원본은 1bpp(8 B/타일)를 4bpp 로 부풀린 것이다.
--
-- 그런데 그 바이트가 **디스크에 없다.**  다 재봤다.
--
--     4bpp 그대로            24 트랙 · BIOS   없음
--     1bpp 타일순 / 래스터    정·반전 모두      없음
--     BIOS 폰트 글리프                        없음
--
-- (첫 판에서 "적중" 이 잔뜩 나왔는데 전부 헛것이었다 -- 바늘이 배경 타일이라
--  전부 $00 이었고 트랙 앞머리의 0 과 맞았다.  바늘 엔트로피를 안 봤다.)
--
-- 그러니 압축돼 있거나 루틴이 그린다.  이 프로브는 그 지점을 잡는다.
--
-- 무엇을 재나
-- ----------
--     VRAM 쓰기   글자 타일 구간($110*32 = $2200 ~ $1F5*32+31 = $3EBF)에
--                 **처음 쓰는 PC** 와 프레임.  거기가 압축 해제 출구다
--     CD 읽기     그 직전에 어느 섹터를 읽었나 ($1802/$1803 포트 경유)
--
-- 왜 이게 갈림길인가
-- ------------------
-- 압축을 이겨서 **다시 압축할** 필요는 없을 수도 있다.  타일이 VRAM 에 앉는
-- 자리와 시점을 알면, 그 뒤에 우리 타일로 덮으면 된다 -- 자막이 이미 하는 일이다.
-- 이 프로브는 "덮을 수 있는 시점이 있는가" 를 확인한다.
--
-- ⚠ 세이브스테이트로 들어가지 말 것.  부팅 직후 화면이라 그럴 이유도 없다.
--
-- 쓰는 법
-- -------
--   1) Mesen 에서 **부팅**한다
--   2) 이 파일을 Script 로 연다  (부팅 전에 열어도 된다 -- 첫 쓰기를 놓치면 안 되니
--      오히려 그 편이 낫다)
--   3) 면책 화면이 지나가고 몇 초 뒤 ★ Stop
--
-- 산출물  C:/snatcher/dump/gfx_0_1_1_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local VRAM = emu.memType.pceVideoRam

local TILE_LO = 0x110 * 32          -- $2200
local TILE_HI = 0x1F5 * 32 + 31     -- $3EBF

local stamp = "session"
if os ~= nil and os.date ~= nil then stamp = os.date("%Y%m%d_%H%M%S") end
local PATH = "C:/snatcher/dump/gfx_0_1_1_" .. stamp .. ".tsv"

local out = assert(io.open(PATH, "w"))
out:write("frame\tkind\taddr\tpc\tdetail\n")

local function say(m) emu.log(m); print(m) end

local frame = 0
local vramWrites = 0
local firstWrite = nil
local writers = {}          -- PC -> 횟수
local recentSectors = {}    -- 최근 CD 읽기

-- CD-ROM 데이터 포트.  섹터 번호를 직접 못 보므로 **읽기가 일어난 프레임**만
-- 남긴다.  타일이 앉는 프레임과 붙여 보면 어느 읽기가 그것인지 좁혀진다.
emu.addMemoryCallback(function(addr, value)
  recentSectors[#recentSectors + 1] = frame
  if #recentSectors > 64 then table.remove(recentSectors, 1) end
end, emu.callbackType.read, 0x1808, 0x1808, CPU, MEM)

emu.addMemoryCallback(function(addr, value)
  -- VRAM 은 워드 주소다.  바이트 구간으로 환산해 비교한다.
  local byteAddr = addr * 2
  if byteAddr < TILE_LO or byteAddr > TILE_HI then return end
  vramWrites = vramWrites + 1
  local pc = emu.getState().cpu.pc or 0
  writers[pc] = (writers[pc] or 0) + 1
  if firstWrite == nil then
    firstWrite = { frame = frame, addr = byteAddr, pc = pc }
    say(string.format("★첫 타일 쓰기  f%d  VRAM $%04X  PC $%04X", frame, byteAddr, pc))
    out:write(string.format("%d\tFIRST\t%04X\t%04X\t\n", frame, byteAddr, pc))
    out:flush()
  end
end, emu.callbackType.write, 0x0000, 0x7FFF, CPU, VRAM)

emu.addEventCallback(function()
  frame = frame + 1
  if frame % 300 == 0 then
    say(string.format("f%d  타일 구간 쓰기 %d 회", frame, vramWrites))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  say("")
  say("끝 -- 글자 타일 구간($2200-$3EBF) 에 쓴 것")
  say(string.format("  총 %d 회", vramWrites))
  out:write("#\n")
  if firstWrite ~= nil then
    say(string.format("  첫 쓰기  f%d  PC $%04X", firstWrite.frame, firstWrite.pc))
  else
    say("  ★한 번도 안 썼다 -- 구간이 틀렸거나 그 화면을 안 지났다")
  end
  local list = {}
  for pc, n in pairs(writers) do list[#list + 1] = { pc = pc, n = n } end
  table.sort(list, function(a, b) return a.n > b.n end)
  for i = 1, math.min(#list, 8) do
    say(string.format("  PC $%04X  x%d", list[i].pc, list[i].n))
    out:write(string.format("0\tWRITER\t\t%04X\t%d\n", list[i].pc, list[i].n))
  end
  if #recentSectors > 0 then
    say(string.format("  CD 데이터 포트 읽기가 있던 마지막 프레임 %d",
                      recentSectors[#recentSectors]))
  end
  out:close()
  say("  " .. PATH)
end, emu.eventType.scriptEnded)

say("GFX 0.1.1 -- 부팅부터 돌려라.  면책 화면이 지나면 Stop")
say("  " .. PATH)
