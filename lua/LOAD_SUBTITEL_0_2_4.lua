-- SUBTITEL 0.2.4 로더 -- 엔진 페이로드를 아케이드 카드에 얹는다
--
-- 왜 로더가 따로 필요한가
-- ---------------------------------------------------------------------------
-- 0.2.4 는 BIOS 와 페이로드가 나뉘어 있다.
--
--     SUBTITEL/0.2.4.pce   BIOS.  AD_PLAY($F61A)/AD_STAT($F6EF) 훅과 케이브($FEC4)
--     SUBTITEL/0.2.4.bin   엔진 152 B.  **AC $1C0500 에 있어야 한다**
--
-- 케이브(cave_manual_ac)가 음성 시작 때 AC $1C0500 에서 152 B 를 RAM $5B80 으로
-- 복사하고 IRQ 벡터를 거기로 돌린다.  그래서 AC 에 미리 얹어두지 않으면 쓰레기를
-- 복사해 실행한다 -- 자막 인계서가 경고한 그 함정이다.
--
-- 쓰는 법
-- ---------------------------------------------------------------------------
--   1. Mesen 펌웨어를 SUBTITEL/0.2.4.pce 로 바꾼다
--   2. 게임을 띄우고 **부팅이 끝난 뒤** 이 스크립트를 실행한다
--   3. 파워사이클/리셋 하면 AC 가 날아가므로 다시 실행해야 한다
--   4. PROBE_MAINLOOP_PC 0.1.0 을 같이 걸어두고 음성 대사까지 간다
--
--     Script -> Settings -> Restrictions -> Allow I/O and OS

local AC = emu.memType.pceArcadeCardRam
local AC_BASE = 0x1C0500          -- cave_manual_ac 의 life.set_ac(a,0x1C0500)
local PATH = "C:/snatcher/SUBTITEL/0.2.4.bin"

local f = io.open(PATH, "rb")
if f == nil then
  emu.log("★ 페이로드를 못 열었다: " .. PATH)
  return
end
local data = f:read("a"); f:close()

for i = 1, #data do
  emu.write(AC_BASE + i - 1, data:byte(i), AC)
end

-- 되읽어 확인한다.  AC 는 포트 경유라 조용히 어긋날 수 있다
local bad = 0
for i = 1, #data do
  if emu.read(AC_BASE + i - 1, AC) ~= data:byte(i) then bad = bad + 1 end
end

if bad == 0 then
  emu.log(string.format("SUBTITEL 0.2.4 페이로드 %d B -> AC $%06X  검증 통과", #data, AC_BASE))
  emu.log("이제 음성 대사까지 가면 된다.  멈추면 30초 더 두고 Stop.")
else
  emu.log(string.format("★ 검증 실패: %d/%d 바이트가 다르다", bad, #data))
end
