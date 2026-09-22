-- PROBE VRAM 덤프 0.1.0 -- 동적 구역이 글자 타일인지 정적으로 대조하려고 뜬다
--
-- 왜
-- ---------------------------------------------------------------------------
-- PROBE_VRAM_FREE 0.1.0 (2026-08-22) 이 VRAM 지도를 냈다:
--
--     $0000-$0FFF   고정            BAT 계열
--     $1000-$13FF   changed 14      SATB
--     $1400-$6FFF   거의 고정       상주 패턴
--     $7000-$7FFF   changed 11~13   ★ 동적 구역
--
-- 대사창 한글은 BIOS 폰트 경로(EX_GETFNT)로 매 대사마다 타일이 올라온다.  그러면
-- 그 타일이 $7000-$7FFF 에 있을 것이고, **이미 올라와 있는 것을 스프라이트가
-- 가리키기만 하면 우리가 패턴을 올릴 일이 없다.**  0.2.4 가 하려던 업로드 자체가
-- 사라진다.
--
-- 눈으로 타일 뷰어를 보는 대신 통째로 떠서 `build/bios_font/Syscard3_galmuri.pce`
-- 의 글리프와 바이트 단위로 대조한다.  맞으면 "글자다" 로 끝나는 게 아니라
-- **어느 타일이 어느 음절인지** 까지 나온다.
--
-- 쓰는 법
-- ---------------------------------------------------------------------------
--   1. 한국어 대사가 화면에 떠 있는 상태로 만든다 (글자가 많을수록 좋다)
--   2. Stop 을 누른다  ->  그 순간의 VRAM 64 KB 가 통째로 저장된다
--
-- 게임을 안 건드리는 수동 관측이다.
--
--     Script -> Settings -> Restrictions -> Allow I/O and OS

local VRAM = emu.memType.pceVideoRam
local BYTES = 0x10000            -- 64 KB

local stamp = "session"
if os ~= nil and os.date ~= nil then stamp = os.date("%Y%m%d_%H%M%S") end
local OUT = "C:/snatcher/dump/vram_" .. stamp .. ".bin"

local frame = 0

emu.addEventCallback(function()
  frame = frame + 1
  if frame % 300 == 0 then
    -- 동적 구역에 지금 얼마나 차 있는지만 알려준다.  많을수록 좋은 순간이다
    local live = 0
    for w = 0x7000, 0x7FFF, 4 do
      local lo = emu.read(w * 2, VRAM)
      local hi = emu.read(w * 2 + 1, VRAM)
      if lo ~= nil and hi ~= nil and (lo ~= 0 or hi ~= 0) then live = live + 1 end
    end
    emu.log(string.format("프레임 %d  |  $7000-$7FFF 표본 %d/1024 가 0 이 아니다  (많을 때 Stop)", frame, live))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  local f = io.open(OUT, "wb")
  if f == nil then emu.log("파일 열기 실패: " .. OUT); return end
  local chunk = {}
  for a = 0, BYTES - 1 do
    local b = emu.read(a, VRAM)
    chunk[#chunk + 1] = string.char(b or 0)
    if #chunk == 4096 then f:write(table.concat(chunk)); chunk = {} end
  end
  if #chunk > 0 then f:write(table.concat(chunk)) end
  f:close()
  emu.log("VRAM 64 KB -> " .. OUT)
end, emu.eventType.scriptEnded)

emu.log("PROBE VRAM 덤프 0.1.0 -- 한국어 대사를 띄운 상태로 Stop 을 눌러라")
