-- PROBE 메인루프 PC 0.1.0 -- 게임이 멈췄을 때 무엇을 기다리는지 본다
--
-- 왜
-- ---------------------------------------------------------------------------
-- SUBTITEL 0.2.4 의 실패 증상은 화면 깨짐이 아니었다:
--
--     "대사 진행이 멈추고 눈만 움직임.  SAT/CR 미사용이나 대사 진행 정지."
--       (SNATCHER_SUBTITLE_RUNTIME_HANDOFF_2026-08-21)
--
-- 눈이 움직였다 = IRQ 도 VDC 도 VRAM 도 살아 있었다.  **멈춘 것은 스크립트 VM 이다.**
-- 그러니 VRAM 주소 문제가 아니라 게임이 무언가를 기다리며 못 나아간 것이다.
--
-- 기준선은 2026-08-22 에 이미 쟀다 (PROBE_IRQ_VS_SATB 0.1.0, 정상 동작 중):
--
--     $4094-$409B   메인 대기 루프
--     $43B1-$43C9   또 다른 대기 루프
--     $80F3 $810A $8107 ...  보조
--
-- 0.2.4 를 얹고 멈춘 상태에서 이 분포가 **어디로 쏠리는지** 보면 범인이 나온다.
-- 정상과 같은 곳이면 VM 이 아니라 그 위쪽이 막힌 것이고, 새 주소가 뜨면 거기다.
--
-- 무엇을 재나
-- ---------------------------------------------------------------------------
--   프레임당 PC 를 한 번만 표집해 히스토그램을 만든다.  뜨거운 루프를 훑는
--   것이 아니라 "지금 어디서 돌고 있나" 만 보면 되므로 이걸로 충분하다.
--   최근 600 프레임 창을 따로 세어, **멈춘 뒤의 분포**만 따로 볼 수 있게 한다.
--
-- 쓰는 법
-- ---------------------------------------------------------------------------
--   정상 판에서 한 번, 0.2.4 에서 한 번 돌려 두 파일을 비교한다.
--   0.2.4 는 멈춘 뒤에도 30 초쯤 더 두고 Stop 해라 -- 멈춘 구간 표본이 쌓인다.
--
--     Script -> Settings -> Restrictions -> Allow I/O and OS

local stamp = "session"
if os ~= nil and os.date ~= nil then stamp = os.date("%Y%m%d_%H%M%S") end
local OUT = "C:/snatcher/dump/probe_mainloop_pc_0_1_0_" .. stamp .. ".tsv"

local WINDOW = 600           -- "최근" 창 크기(프레임)

local frame = 0
local hist, recent, ring = {}, {}, {}

local function pc()
  local ok, s = pcall(emu.getState)
  if not ok or s == nil then return nil end
  return s["cpu.pc"] or s["cpu.programCounter"] or s["pc"]
end

emu.addEventCallback(function()
  frame = frame + 1
  local p = pc()
  if p == nil then return end
  hist[p] = (hist[p] or 0) + 1

  -- 최근 WINDOW 프레임만 따로 센다
  local slot = frame % WINDOW
  local old = ring[slot]
  if old ~= nil then recent[old] = (recent[old] or 0) - 1 end
  ring[slot] = p
  recent[p] = (recent[p] or 0) + 1

  if frame % 300 == 0 then
    local best, bn = nil, -1
    for a, n in pairs(recent) do if n > bn then best, bn = a, n end end
    emu.log(string.format("프레임 %d  |  최근 %d 프레임 중 $%04X 가 %d 번 (%.0f%%)",
      frame, WINDOW, best or 0, bn, 100 * bn / math.min(frame, WINDOW)))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  local f = io.open(OUT, "wb")
  if f == nil then emu.log("파일 열기 실패: " .. OUT); return end
  f:write("kind\tpc\tcount\tpct\n")
  f:write(string.format("FRAMES\t\t%d\t\n", frame))
  local function dump(tag, tbl, total)
    local list = {}
    for a, n in pairs(tbl) do if n > 0 then list[#list + 1] = { a = a, n = n } end end
    table.sort(list, function(x, y) return x.n > y.n end)
    for i = 1, math.min(#list, 40) do
      f:write(string.format("%s\t%04X\t%d\t%.1f\n", tag, list[i].a, list[i].n,
        100 * list[i].n / math.max(total, 1)))
    end
  end
  dump("ALL", hist, frame)
  dump("RECENT", recent, math.min(frame, WINDOW))
  f:close()
  emu.log("PROBE 메인루프 PC 0.1.0 -> " .. OUT)
end, emu.eventType.scriptEnded)

emu.log("PROBE 메인루프 PC 0.1.0 시작 -- 멈춘 뒤에도 30초쯤 더 두고 Stop 해라")
