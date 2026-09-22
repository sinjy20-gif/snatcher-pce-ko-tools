-- PROBE 트램펄린호출자 0.1.0 -- **$7F88 을 게임이 직접 부르는가**
--
-- 왜 이걸 보나 (소유자 지적, 2026-08-19)
-- ---------------------------------------------------------------------------
-- "어차피 여기 우리 렌더러 자리 아니잖아" -- 맞다.  그게 이 사건의 역설이다:
-- 우리 프리로더는 그 화면에서 포인터를 **거부하고 빠져나온다**.  그런데도
-- 우리 디스크에서만 죽는다.
--
-- 그러면 렌더러 말고 **우리가 덮어쓴 다른 것**을 봐야 한다.  하나 있다:
--
--     build_ac_dynamic_0_1_5.py:
--       "$7F88 trampoline slot is 100 bytes of **the original CD loader**"
--
-- $7F88 은 원래 **게임의 CD 로더** 자리다.  우리가 100 바이트를 덮어썼다.
-- 우리 프리로더가 그것을 부르므로 문제없다고 보았지만, **게임이 자기 루틴인 줄
-- 알고 직접 부르면** 전혀 다른 것이 실행된다.  상점에서만 죽는 것과 맞아떨어진다.
--
-- 무엇을 재나
-- ---------------------------------------------------------------------------
-- $7F88 진입 순간 스택 맨 위의 복귀주소가 곧 호출자다 (JSR 이 밀어 넣은 값).
-- `emu.getState()` 없이 SP 만 알면 되는데 SP 는 getState 로만 얻으므로, 진입은
-- 드물다는 점을 이용해 여기서만 부른다 (렌더링 1 회당 몇 번 수준).
--
--     호출자가 $5E40-$5FFF   우리 프리로더 -- 정상
--     그 외                  ★ 게임이 원래 CD 로더인 줄 알고 부른 것
--
-- 0 이면 이 가설도 기각이다.
--
-- 돌리는 법
-- ---------------------------------------------------------------------------
--   조이 디비전 -> 쇼핑하기.  화면에 실시간으로 우리/게임 호출 수가 뜬다.
--   출력: C:\snatcher\dump\probe_tramp_caller_0_1_0.tsv

local OUT = "C:\\snatcher\\dump\\probe_tramp_caller_0_1_0.tsv"
local mem = emu.memType.pceMemory

local TRAMP = 0x7F88
local OURS_LO, OURS_HI = 0x5E40, 0x5FFF   -- 프리로더 범위
local STACK = 0x2100
local BOOT_GRACE = 180

local file = assert(io.open(OUT, "w"))
file:write("kind\tframe\tcaller\tnote\n")

local frame, ours, theirs, logged, fired = 0, 0, 0, 0, false
local dirty = false
local seen = {}

local function byte(a) return emu.read(a, mem) or 0 end

emu.addMemoryCallback(function()
  local ok, s = pcall(emu.getState)
  if not ok or s == nil then return end
  local sp = s["cpu.sp"] or 0
  -- JSR 은 PCH 를 먼저, PCL 을 다음에 민다.  SP+1 이 PCL, SP+2 가 PCH
  local lo = byte(STACK + ((sp + 1) % 256))
  local hi = byte(STACK + ((sp + 2) % 256))
  local caller = (hi * 256 + lo + 1) % 0x10000    -- 밀린 값은 복귀주소-1

  if caller >= OURS_LO and caller <= OURS_HI then
    ours = ours + 1
    return
  end
  theirs = theirs + 1
  if not seen[caller] then
    seen[caller] = 0
    if logged < 40 then
      logged = logged + 1
      file:write(string.format("★게임\t%d\t%04X\t게임이 원래 CD 로더 자리를 직접 불렀다\n",
        frame, caller))
      dirty = true
    end
  end
  seen[caller] = seen[caller] + 1
end, emu.callbackType.exec, TRAMP, TRAMP, emu.cpuType.pce, mem)

local function finish(reason)
  file:write(string.format("\n-- %s · 프레임 %d\n", reason, frame))
  file:write(string.format("-- $7F88 호출: 우리 프리로더 %d · **게임 %d**\n", ours, theirs))
  local t = {}
  for k, v in pairs(seen) do t[#t + 1] = string.format("$%04X x%d", k, v) end
  table.sort(t)
  file:write("-- 게임 쪽 호출자: " .. (#t > 0 and table.concat(t, " · ") or "없음") .. "\n")
  if theirs == 0 then
    file:write("-- 판정: 게임은 $7F88 을 안 부른다.  이 가설 기각\n")
  else
    file:write("-- 판정: ★ 게임이 부른다.  우리가 덮어쓴 원래 CD 로더가 범인이다\n")
  end
  file:flush()
end

emu.addMemoryCallback(function()
  if frame > BOOT_GRACE and not fired then
    fired = true
    finish("폭주 -- I/O 페이지 실행")
  end
end, emu.callbackType.exec, 0x0000, 0x1FFF, emu.cpuType.pce, mem)

emu.addEventCallback(function()
  frame = frame + 1
  if dirty then file:flush() dirty = false end
  emu.drawString(4, 4, string.format("$7F88 호출 · 우리 %d · 게임 %d", ours, theirs),
    theirs > 0 and 0xFF6060 or 0x80FF80, 0x80000000, 1)
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if not fired then finish("정지") end
  file:close()
end, emu.eventType.scriptEnded)

emu.log("PROBE 트램펄린호출자 0.1.0 -- $7F88 을 게임이 직접 부르는지 본다")
emu.log("  '게임 N' 이 0 이 아니면 우리가 덮어쓴 원래 CD 로더가 범인이다")
emu.log("  출력: " .. OUT)
