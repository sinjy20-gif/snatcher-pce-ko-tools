-- PROBE 죽은 RAM 0.1.1 -- 컷신 구간만 · MPR2 도 함께
--
-- 0.1.0 이 왜 부족했나
-- ---------------------------------------------------------------------------
-- 결과: $2200-$3FFF 에 안 쓰인 자리 101 B / 14 조각, 최대 19 B.  64 B 연속 0 개.
-- 그런데 두 가지가 잘못됐다.
--
--   1  **타이틀·부팅까지 셌다.**  §4 가 말한 것은 "컷신 동안" 죽은 RAM 이다.
--      부팅에서 한 번 초기화되고 컷신 중에는 안 쓰이는 자리가 통째로 빠졌다.
--      컷신은 대화·메뉴·세이브가 다 멈춘, 압박이 제일 낮은 상태다 -- 그것이 §4 의
--      논거인데 그 조건을 안 지켰다.
--
--   2  **$4000-$5FFF (MPR2=$68) 를 안 봤다.**  여기가 오히려 1 순위다:
--      게임의 IRQ1 핸들러 $40A4 가 사는 창이고, 모든 표본에서 MPR2=$68 로 고정이며,
--      CD 워크램이라 쓰기가 된다.  8 KB 다.
--
-- 그래서 0.1.1 은 **CD_PLAY 가 나간 뒤부터** 세고, 창을 넓게 본다.
--
-- 1 순위 후보: $5C40-$5E1F (480 B)
-- ---------------------------------------------------------------------------
-- 어제 BIOS 폰트 전환으로 글리프 루프를 뺐다.  그래서 레코드 캐시의 슬롯 3-17 이
-- 죽었다 -- 자리를 찾은 것이 아니라 **우리가 만든 것**이다.
--
--     $5B80-$5BDF    96 B   텍스트          여전히 쓴다
--     $5BE0-$5C3F    96 B   상수 슬롯 0-2    여전히 쓴다 (F040/41/42)
--     $5C40-$5E1F   480 B   글리프 슬롯 3-17  ★ 죽었다
--     $5E20-$5E3F    32 B   반칸 도우미 18    남겨둠
--
-- MPR2 창이라 항상 매핑된다.  POC 훅 64 B 는 넉넉히 들어간다.
--
-- **다만 공짜라고 단정하면 네 번째로 데인다.**  SNATCHER_SAVELOAD_HANDOFF 가
-- `$5B80-$5E3F` 를 "게임이 돌려 쓰는 공용 버퍼" 라고 못 박았고, 상수 검사 코드가
-- 있는 이유도 "헬퍼 밖의 무언가가 그 범위에 닿는다" 는 실측이었다.
-- (`$5B80` · `$BFCF` · `$7FF1` -- 빈 자리로 봤다가 세 번 틀렸다.)
--
-- 그러나 §4 의 논거가 정확히 여기 걸린다: **컷신 중에는 대화 시스템이 안 돈다.**
-- 레코드 캐시를 쓰는 주체가 멈춰 있다.  이 프로브가 그것을 확인한다.
--
-- 게이트
-- ---------------------------------------------------------------------------
--     $E012 (CD_PLAY) 가 실행되면 그때부터 기록 시작.  그 전 쓰기는 버린다.
--     오프닝 t0 가 정확히 거기다 (PROBE_OPENING_HOOK_0.1.1 에서 프레임 1077).
--
-- 필요한 크기
-- ---------------------------------------------------------------------------
--     POC 훅          64 B      이것만 되면 자막이 화면에 뜬다
--     엔진 전체    1,140 B      패턴버퍼 576 + 인터프리터 300 + SAT 128 + 나머지
--     조각나도 된다 -- 버퍼와 코드를 나눠 두면 그만이다
--
-- 돌리는 법
-- ---------------------------------------------------------------------------
--   타이틀에서 오프닝이 시작되게 두고 끝까지.  CD_PLAY 전에는 아무것도 안 센다.
--   Stop 을 눌러야 파일이 닫힌다.

local OUT = "C:\\snatcher\\dump\\probe_dead_ram_0_1_1.tsv"
local mem = emu.memType.pceMemory

-- 순서가 곧 우선순위다.  1 번이 제일 유력하다.
local RANGES = {
  {0x5C40, 0x5E1F, "★ 죽은 글리프 슬롯 3-17 (BIOS 전환으로 우리가 비웠다)"},
  {0x5B80, 0x5E3F, "레코드 캐시 전체 (게임이 돌려 쓴다고 기록됨)"},
  {0x4000, 0x5FFF, "MPR2 $68 CD워크램 ($40A4 가 사는 창)"},
  {0x2200, 0x3FFF, "MPR1 $F8 베이스RAM (0.1.0 에서 101 B 뿐이었다)"},
}
local CD_PLAY = 0xE012
local NEED_POC, NEED_ENGINE = 64, 1140

local file = assert(io.open(OUT, "w"))
file:write("kind\tframe\tstart\tsize\tnote\n")

local frame, rows = 0, 0
local armed, armFrame = false, -1
local touched = {}
local writes, dropped = 0, 0

local function row(kind, a, b, note)
  rows = rows + 1
  file:write(string.format("%s\t%d\t%s\t%s\t%s\n", kind, frame,
    tostring(a or ""), tostring(b or ""), note or ""))
end

emu.addMemoryCallback(function()
  if not armed then
    armed = true
    armFrame = frame
    row("arm", frame, "", "CD_PLAY -- 여기부터 센다 (이전 쓰기는 버렸다)")
  end
end, emu.callbackType.exec, CD_PLAY, CD_PLAY, emu.cpuType.pce, mem)

-- 콜백은 최대한 가볍게.  무거우면 예산을 다 먹는다
for _, r in ipairs(RANGES) do
  emu.addMemoryCallback(function(address)
    if armed then touched[address] = true; writes = writes + 1
    else dropped = dropped + 1 end
  end, emu.callbackType.write, r[1], r[2], emu.cpuType.pce, mem)
end

emu.addEventCallback(function() frame = frame + 1 end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if not armed then
    row("warn", 0, 0, "CD_PLAY 가 한 번도 안 나갔다 -- 오프닝을 못 봤다.  다시 돌릴 것")
  end
  for _, rg in ipairs(RANGES) do
    local LO, HI, name = rg[1], rg[2], rg[3]
    local runs, start = {}, nil
    for a = LO, HI do
      if touched[a] then
        if start then runs[#runs+1] = {start, a - start}; start = nil end
      else
        if not start then start = a end
      end
    end
    if start then runs[#runs+1] = {start, HI + 1 - start} end
    table.sort(runs, function(x, y) return x[2] > y[2] end)

    local total, poc, eng = 0, 0, 0
    for _, x in ipairs(runs) do
      total = total + x[2]
      if x[2] >= NEED_POC then poc = poc + 1 end
      if x[2] >= NEED_ENGINE then eng = eng + 1 end
    end
    for i = 1, math.min(#runs, 16) do
      local s, n = runs[i][1], runs[i][2]
      local tag = ""
      if n >= NEED_ENGINE then tag = "★ 엔진 전체가 들어간다"
      elseif n >= NEED_POC then tag = "★ POC 훅이 들어간다" end
      row("run", string.format("$%04X", s), n,
          string.format("%s  $%04X-$%04X  %d B  %s", name, s, s + n - 1, n, tag))
    end
    row("sum", total, #runs,
        string.format("%s : 안 쓰인 %d B / %d 조각 · 64B+ %d 개 · 1140B+ %d 개",
          name, total, #runs, poc, eng))
  end
  file:write(string.format("-- 프레임 %d (게이트 %d) · 센 쓰기 %d · 버린 쓰기 %d · 총 %d 행\n",
    frame, armFrame, writes, dropped, rows))
  file:close()
end, emu.eventType.scriptEnded)

emu.log("PROBE 죽은 RAM 0.1.1 -- CD_PLAY 이후만 센다 · MPR1 과 MPR2 둘 다")
emu.log("  0.1.0 은 타이틀까지 세서 101 B 밖에 못 찾았다.  컷신 구간만 봐야 한다")
emu.log("  run 행: 64 B 이상이면 POC, 1,140 B 이상이면 엔진 전체")
emu.log("  arm 행이 없으면 오프닝을 못 본 것 -- 다시 돌릴 것")
emu.log("  출력: " .. OUT)
