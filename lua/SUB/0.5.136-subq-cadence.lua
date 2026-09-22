-- SUB 0.5.136 -- CD_SUBQ 가 얼마나 자주 갱신되는가 (쓰기 0 B)
--
-- 어디까지 왔나
-- ---------------------------------------------------------------------------
-- 0.5.135 로 형식이 확정됐다.  $20A0 은 표준 CD 서브채널 Q 블록이다:
--
--     $20A2    현재 트랙 (BCD)          17 · 21 확인
--     $20A4~6  트랙 상대 MSF (BCD)      00:00:00 -> 00:00:05
--     $20A7~9  절대 MSF (BCD)           40:53:41
--              LBA = (분×60 + 초)×75 + 프레임    ★-150 없음 · 표본 4/4 오차 0
--
-- 그리고 게임이 이미 그것을 받아온다:
--
--     $6111  LDA #$A0 / STA $FA / LDA #$20 / STA $FB / JSR $E01E (CD_SUBQ)
--     $6230  per-frame CD_STAT poll
--
-- ★ 남은 것은 **갱신 주기**다.
--   자막 구간 전환을 이 값으로 판정하려면, 값이 얼마나 자주·규칙적으로
--   새로워지는지 알아야 한다.  드문드문 갱신되면 전환이 늦게 잡힌다.
--
-- 무엇을 재나
-- ---------------------------------------------------------------------------
--     ① $6111 (CD_SUBQ 호출부) exec 횟수 · 프레임당 몇 번인가
--     ② $20A4~9 가 바뀌는 프레임 간격
--     ③ 한 번 바뀔 때 LBA 가 몇 섹터 나아가는가
--
-- 기대값
--     CD 는 75 섹터/초, 화면은 60 프레임/초 -> 프레임당 1.25 섹터
--     매 프레임 갱신되면 델타가 1~2 를 오간다
--     드문드문이면 델타가 크게 튄다 -> 그만큼 전환이 늦는다
--
-- 읽는 법
-- ---------------------------------------------------------------------------
--     간격 1~2 프레임 · 델타 1~2 섹터    ★충분하다.  구간 전환을 바로 잡는다
--     간격이 크다 (10 프레임 이상)        전환이 늦게 잡힌다.  보정이 필요할 수 있다
--     $6111 이 안 걸린다                  게임이 다른 자리에서 부른다
--                                         -> "안 부른다" 가 아니라 "이 자리가 아니다"
--
-- ⚠ CD-DA 가 안 도는 구간에서는 값이 멈춰 있다.  그건 정상이다.
--   판정은 **재생 중** 구간만 보고 할 것 (트랙 번호가 0 이 아닌 동안).
--
-- ★ 화면에 아무것도 안 그린다.  게임을 한 바이트도 안 고친다.
--
--   BIOS  build/patch/0.4.6.68/Syscard3_galmuri_0.4.6.68.pce
--   CUE   같은 폴더 [KO].cue
--   Power Cycle -> 이 파일만 로드 -> 오프닝 CD-DA 재생
--
-- 산출물  C:/snatcher/dump/subq_cadence_0_5_136_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local SUBQ = 0x20A0
local CALL = 0x6111          -- CD_SUBQ 호출부 (verify_cdda_native_contract.py)
local POLL = 0x6230          -- per-frame CD_STAT poll

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/subq_cadence_0_5_136_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\ttrack\trel_lba\tabs_lba\tdelta_lba\tgap_frames\tcall6111\tpoll6230\n')

local function say(f, ...) emu.log(string.format(f, ...)) end
local function rd(a)
  local ok, v = pcall(emu.read, a, MEM)
  return (ok and type(v) == 'number') and v or 0
end
local function bcd(b)
  local hi, lo = b >> 4, b & 0x0F
  if hi > 9 or lo > 9 then return -1 end
  return hi * 10 + lo
end
local function msf(a)
  local m, s, f = bcd(rd(a)), bcd(rd(a + 1)), bcd(rd(a + 2))
  if m < 0 or s < 0 or f < 0 then return -1 end
  return (m * 60 + s) * 75 + f
end

local calls, polls = 0, 0
emu.addMemoryCallback(function() calls = calls + 1 end,
  emu.callbackType.exec, CALL, CALL, CPU, MEM)
emu.addMemoryCallback(function() polls = polls + 1 end,
  emu.callbackType.exec, POLL, POLL, CPU, MEM)

local frame, lastFrame, lastAbs = 0, -1, -1
local gaps, deltas, rows = {}, {}, 0
local totalCalls, totalPolls = 0, 0

emu.addEventCallback(function()
  frame = frame + 1
  totalCalls = totalCalls + calls
  totalPolls = totalPolls + polls

  local trk = bcd(rd(SUBQ + 2))
  local rel = msf(SUBQ + 4)
  local abs = msf(SUBQ + 7)

  if abs >= 0 and abs ~= lastAbs then
    local gap = (lastFrame >= 0) and (frame - lastFrame) or 0
    local dlt = (lastAbs >= 0) and (abs - lastAbs) or 0
    if lastFrame >= 0 then
      gaps[#gaps + 1] = gap
      deltas[#deltas + 1] = dlt
    end
    out:write(string.format('%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n',
      frame, trk, rel, abs, dlt, gap, calls, polls))
    out:flush()
    rows = rows + 1
    if rows <= 25 then
      say('f%-6d 트랙%-3d rel=%-6d abs=%-7d Δ%-4d 간격%-3d  $6111×%d $6230×%d',
          frame, trk, rel, abs, dlt, gap, calls, polls)
    end
    lastAbs, lastFrame = abs, frame
  end
  calls, polls = 0, 0
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:close()
  local function stat(t)
    if #t == 0 then return '-' end
    local s, mn, mx = 0, t[1], t[1]
    for _, v in ipairs(t) do s = s + v; if v < mn then mn = v end; if v > mx then mx = v end end
    return string.format('평균 %.2f · 최소 %d · 최대 %d', s / #t, mn, mx)
  end
  say('0.5.136 끝 -- 갱신 %d 회 / %d 프레임', rows, frame)
  say('   갱신 간격(프레임) : %s', stat(gaps))
  say('   LBA 증가(섹터)    : %s', stat(deltas))
  say('   $6111 호출 총 %d · $6230 총 %d', totalCalls, totalPolls)
  if totalCalls == 0 then
    say('0.5.136 ⚠ $6111 이 한 번도 안 걸렸다.  게임이 다른 자리에서 부른다.')
    say('0.5.136   "안 부른다" 가 아니라 "이 자리가 아니다" 다')
  end
  if rows == 0 then
    say('0.5.136 ⚠ $20A0 이 안 변했다.  CD-DA 를 재생하는 구간을 지났는지 볼 것')
  end
  say('0.5.136 저장 %s', PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.136-subq-cadence armed -- 순수 관측 · 게임 무수정 · 화면 무개입')
say('  묻는 것 : CD_SUBQ 갱신 주기.  구간 전환을 제때 잡을 수 있는가')
say('  기대 : 75 섹터/초 ÷ 60 프레임/초 = 프레임당 1.25 섹터')
say('  덤프 : ' .. PATH)
