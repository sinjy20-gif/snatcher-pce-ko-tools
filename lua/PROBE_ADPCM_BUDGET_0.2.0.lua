-- PROBE_ADPCM_BUDGET 0.2.0 - 음성 재생이 프레임 예산을 정말 갉아먹는가
--
-- 0.1.x 와 다른 질문이다
-- ----------------------
-- 0.1.1 은 "게임이 ADPCM 재생 상태를 스스로 아는가"를 물었고 답을 얻었다.
-- 이 프로브는 그 다음 질문을 잰다.
--
--   SNATCHER_UI_FLICKER_HANDOFF_2026-08-14 의 남은 증상:
--     음성 전   10회 중 약 3 에서 깜빡임
--     음성 후   10회 중 약 9,  그리고 되돌아오지 않는다
--
--   가설: 게임이 음성 재생 이후 ADPCM 서비스를 계속 돌려 프레임 예산을 잃는다.
--
-- **되돌아오지 않는다**가 핵심이다.  재생 중에만 무거우면 그건 당연한 비용이고,
-- 재생이 끝났는데도 폴링이 안 내려가면 그때가 예산 손실이다.  그래서 구간을
-- 셋으로 갈라 잰다.
--
--   pre    이 세션에서 아직 음성이 한 번도 안 나옴
--   play   재생 중
--   post   재생이 끝난 뒤
--
-- 무엇을 예산의 대리 지표로 쓰나
-- ------------------------------
-- 프레임당 ADPCM I/O($1800-$180F) 읽기 횟수다.  게임이 스스로 그 창을 얼마나
-- 자주 들여다보는지가 곧 거기에 쓰는 CPU 다.  스캔라인을 직접 읽는 방법도
-- 있지만 Mesen 의 PCE 상태 키에 의존하게 되고, 이 값은 의존이 없다.
--
-- 같이 세는 것: 우리 헬퍼의 copy_record 호출.  "우리 비용"과 "게임 비용"이
-- 같은 표에 있어야 어느 쪽이 늘었는지 말할 수 있다.
--
-- 고치지 않는다
-- -------------
-- 계측 전용이다.  폐공장 깜빡임은 손대지 않는다 -- 숫자를 보고 판단하는 것은
-- 사람이다.
--
-- 0.1.0 이 에뮬을 세운 실수는 반복하지 않는다
-- --------------------------------------------
-- read 콜백 안에서 emu.getState() 를 부르면 프레임당 수백 번 돈다.  콜백은
-- 카운터만 올리고, getState 는 프레임 끝에서 한 번만 부른다.
--
-- 쓰는 법
--   1) 아래 BUILD 를 지금 돌릴 디스크에 맞춘다
--   2) 파워사이클에서 시작한다 (pre 구간이 있어야 비교가 된다)
--   3) 음성 대사가 있는 장면을 지난 뒤, 같은 메뉴를 음성 전/후로 열어본다
--   4) 깜빡인 순간마다 E 키
--   5) Stop  (Stop 해야 census 가 남는다)

local cpu = emu.memType.cpu

-- helper_symbols.json 에서 옮긴 값.  디스크를 다시 빌드하면 반드시 대조할 것.
local BUILD = "prenone"     -- "prenone" | "preresident" | "preall"
local SYMBOLS = {
  prenone     = { COPY_RECORD = 0xBDE9 },
  preresident = { COPY_RECORD = 0xBDF4 },
  preall      = { COPY_RECORD = 0xBDEA },
}
local S = assert(SYMBOLS[BUILD], "BUILD 이름이 SYMBOLS 에 없다: " .. tostring(BUILD))

local IO_LO, IO_HI = 0x1800, 0x180F
local BIOS_CD_READ = 0xE009

local OUT = string.format("C:\\snatcher\\dump\\adpcm_budget_v020_%s_%s.tsv",
                          BUILD, os.date("%H%M%S"))
local file = assert(io.open(OUT, "w"))
file:write("kind\tframe\tphase\tadpcm_reads\tcopies\tcdreads\tvoices\tnote\n")
file:flush()

local frame       = 0
local closed      = false
local playing     = false
local everPlayed  = false
local voices      = 0

local reads, copies, cdreads = 0, 0, 0
-- 구간별 프레임당 읽기 수를 모아 둔다.  평균만으로는 "가끔 튀는 것"과
-- "계속 높은 것"이 구분되지 않으므로 분포가 필요하다.
local samples = { pre = {}, play = {}, post = {} }
local totals  = { pre = 0, play = 0, post = 0 }
local copySum = { pre = 0, play = 0, post = 0 }

local function phase()
  if playing then return "play" end
  return everPlayed and "post" or "pre"
end

local function row(kind, note)
  if closed then return end
  file:write(string.format("%s\t%d\t%s\t%d\t%d\t%d\t%d\t%s\n",
    kind, frame, phase(), reads, copies, cdreads, voices, note or ""))
  file:flush()
end

emu.addMemoryCallback(function()
  reads = reads + 1
end, emu.callbackType.read, IO_LO, IO_HI, emu.cpuType.pce, cpu)

emu.addMemoryCallback(function()
  copies = copies + 1
end, emu.callbackType.exec, S.COPY_RECORD, S.COPY_RECORD, emu.cpuType.pce, cpu)

emu.addMemoryCallback(function()
  cdreads = cdreads + 1
end, emu.callbackType.exec, BIOS_CD_READ, BIOS_CD_READ, emu.cpuType.pce, cpu)

local lastMark = 0

emu.addEventCallback(function()
  frame = frame + 1

  local ok, state = pcall(emu.getState)
  local nowPlaying = ok and state and state["cdrom.adpcm.playing"] == true or false
  if nowPlaying ~= playing then
    playing = nowPlaying
    if playing then
      everPlayed = true
      voices = voices + 1
      row("voice", "재생 시작")
    else
      row("voice", "재생 종료 -- 여기서부터 post 구간")
    end
    emu.log(string.format("ADPCM %s f%d (%d번째)",
      playing and "START" or "END", frame, voices))
  end

  -- F5 는 Mesen 세이브 스테이트라 쓰지 않는다.
  if emu.isKeyPressed("E") and (lastMark == 0 or frame - lastMark > 30) then
    lastMark = frame
    row("MARK", "여기서 깜빡였다")
    emu.log(string.format("---- MARK f%d (%s) ----", frame, phase()))
  end

  local p = phase()
  local bucket = samples[p]
  bucket[#bucket + 1] = reads
  totals[p] = totals[p] + reads
  copySum[p] = copySum[p] + copies

  -- 레코드를 그린 프레임만 남긴다.  전 프레임을 찍으면 파일이 수십만 줄이 되고,
  -- 우리가 궁금한 것은 "우리 작업이 있던 프레임의 게임 부하"다.
  if copies > 0 then row("frame", "") end

  reads, copies, cdreads = 0, 0, 0
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  local function stats(name)
    local list = samples[name]
    local n = #list
    if n == 0 then return name .. " 프레임 0" end
    table.sort(list)
    -- Lua 5.4 는 정수 표현이 없는 실수를 %d 로 거부한다.  나눗셈은 %.1f 로.
    return string.format(
      "%s 프레임 %d · 프레임당 읽기 평균 %.1f 중앙값 %d 최대 %d · copy_record %d",
      name, n, totals[name] / n, list[math.floor(n / 2) + 1], list[n],
      copySum[name])
  end
  for _, name in ipairs({ "pre", "play", "post" }) do
    reads, copies, cdreads = 0, 0, 0
    row("census", stats(name))
  end
  -- 판정을 로그에 직접 적어 둔다.  숫자만 남기면 나중에 다시 해석해야 한다.
  local pre = #samples.pre > 0 and totals.pre / #samples.pre or 0
  local post = #samples.post > 0 and totals.post / #samples.post or 0
  local verdict
  if #samples.post == 0 then
    verdict = "post 구간 없음 -- 음성을 한 번도 안 지났다"
  elseif post > pre * 1.2 then
    verdict = string.format(
      "post 가 pre 보다 %.1f배 높다 -- 예산 손실 가설이 지지된다", post / math.max(pre, 0.01))
  else
    verdict = string.format(
      "post %.1f vs pre %.1f -- 폴링은 안 늘었다. 원인은 다른 곳이다", post, pre)
  end
  row("census", verdict)
  closed = true
  file:close()
  emu.log(string.format("PROBE_ADPCM_BUDGET 0.2.0 [%s]: 음성 %d회 -> %s",
    BUILD, voices, OUT))
  emu.log("  " .. verdict)
end, emu.eventType.scriptEnded)

-- BUILD 을 손으로 맞추다 틀리면 조용히 남의 주소를 잡는다.  디스크 이름을
-- 직접 찍어 두면 로그만 보고도 가려진다 (PROBE_PRELOAD_STALL 에서 실제로
-- [KO 0.3.4] 를 preresident 로 한 판 기록한 적이 있다).
do
  local ok, info = pcall(emu.getRomInfo)
  local name = (ok and info and (info.name or info.path)) or "?"
  emu.log("  디스크: " .. tostring(name))
  if not tostring(name):find(BUILD, 1, true) then
    emu.log("  *** 경고: 디스크 이름에 BUILD 문자열이 없다 ***")
  end
end
emu.log(string.format("PROBE_ADPCM_BUDGET 0.2.0 loaded  (BUILD=%s)", BUILD))
emu.log("  재는 것: 프레임당 ADPCM I/O 읽기 = 게임이 ADPCM 에 쓰는 CPU")
emu.log("  가르는 것: pre(음성 전) / play(재생 중) / post(재생 후)")
emu.log("  핵심은 post 가 pre 로 안 돌아오는가다")
emu.log("  파워사이클에서 시작할 것.  깜빡이면 E 키.  Stop 해야 census 가 남는다")
emu.log("  출력: " .. OUT)
