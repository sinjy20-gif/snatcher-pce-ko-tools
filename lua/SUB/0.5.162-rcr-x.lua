-- SUB 0.5.162 -- RCR 상위 바이트(X)가 정말 항상 0 인가
--
-- ★ 순수 관측.  아무것도 안 고친다.
--
-- 왜 재나
-- ---------------------------------------------------------------------------
-- 0.4.6.74 는 BIOS 의 RCR 설정 루틴 한복판 `$E424` 를 훅한다.  그런데 그 루틴은
-- 조금 뒤에서 **X 를 RCR 상위 바이트로 쓴다**:
--
--     $E41F  PHA / LDA #$06 / STA $F7
--     $E424  STA $0000        <- 훅 자리
--     $E427  PLA / STA $0002  (RCR 하위)
--     $E42B  STX $0003        <- ★ X 를 쓴다
--     $E42E  RTS
--
-- 뱅크1 디스패처는 진입하자마자 `TSX` 로 X 를 덮는다.  그래서 훅 꼬리에서
-- `LDX #$00` 으로 되돌려 놓았다.  근거는 "이 게임이 쓰는 RCR 은 71 · 199 · 212
-- 뿐이라 전부 256 미만" 이라는 **관측**이다.  그것을 전수로 확인한다.
--
-- ⚠ 0 이 아닌 X 가 한 번이라도 나오면 `LDX #$00` 은 틀렸고, 그 프레임의 래스터
--   분할이 깨진다.  그때는 훅 자리를 다시 골라야 한다.
--
-- 어디에 쓰나
--     0.4.6.72 (훅 없음)  -> 원래 X 가 무엇인지.  이것이 진짜 근거다
--     0.4.6.74 (훅 있음)  -> 우리 LDX #$00 뒤에도 같은 값인지
--
-- 산출물  C:/snatcher/dump/rcr_x_0_5_162_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local STX_RCR_HI = 0xE42B          -- STX $0003

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/rcr_x_0_5_162_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tline\trcr_lo\trcr_x\tcount\n')

local function say(m) emu.log(m); print(m) end

local SK, XK, AK = nil, nil, nil
local function st()
  local ok, s = pcall(emu.getState)
  return ok and s or nil
end
local function pick(s, cands)
  for _, k in ipairs(cands) do if type(s[k]) == 'number' then return k end end
  return false
end

local frame, seen, bad = 0, {}, 0

emu.addMemoryCallback(function()
  local s = st(); if not s then return end
  if SK == nil then
    SK = pick(s, {'vdc.scanline'}) or false
    XK = pick(s, {'cpu.x', 'x'}) or false
    AK = pick(s, {'cpu.a', 'a'}) or false
    say(('  키: scanline=%s x=%s a=%s'):format(tostring(SK), tostring(XK), tostring(AK)))
  end
  local line = (SK and s[SK]) or -1
  local x    = (XK and s[XK]) or -1
  -- RCR 하위는 방금 $0002 에 쓴 값 = 그 시점 A 가 아니라 이미 저장됐다.
  -- $E428 이 STA $0002 이므로 여기서는 A 가 그대로 RCR 하위다.
  local lo   = (AK and s[AK]) or -1

  local key = ('%d/%d'):format(lo, x)
  seen[key] = (seen[key] or 0) + 1
  if x ~= 0 and x ~= -1 then
    bad = bad + 1
    if bad <= 20 then
      say(('★X≠0  f%-7d line=%-3d RCR lo=%d  X=%d  ← LDX #$00 이 틀렸다')
            :format(frame, line, lo, x))
    end
  end
  if seen[key] == 1 then
    say(('  새 조합  RCR lo=%-4d X=%-3d  (line %d)'):format(lo, x, line))
    out:write(('%d\t%d\t%d\t%d\t1\n'):format(frame, line, lo, x))
    out:flush()
  end
end, emu.callbackType.exec, STX_RCR_HI, STX_RCR_HI + 2, CPU, MEM)

emu.addEventCallback(function() frame = frame + 1 end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:write('# 조합별 횟수\n')
  for k, n in pairs(seen) do out:write(('# %s\t%d\n'):format(k, n)) end
  out:write(('# X!=0 %d 회\n'):format(bad))
  out:close()
  local parts = {}
  for k, n in pairs(seen) do parts[#parts+1] = ('%s x%d'):format(k, n) end
  say('끝 -- RCR lo/X 조합: ' .. table.concat(parts, ' · '))
  say(('     X != 0 은 %d 회'):format(bad))
end, emu.eventType.scriptEnded)

say('SUB 0.5.162-rcr-x armed -- 순수 관측')
say('  ★ 볼 것: X 가 전부 0 인가.  하나라도 0 이 아니면 훅 자리를 다시 골라야 한다')
say('  ' .. PATH)
