-- SUB 0.5.164 -- RCR 상위 바이트(X) 재기 · 심박 포함
--
-- ★ 순수 관측.  0.5.162 가 아무것도 안 뱉어서 원인을 가르려고 만들었다.
--
-- 0.5.162 는 콜백 안에서만 출력했다.  그래서 "콜백이 안 걸렸다" 와
-- "이 장면이 그 루틴을 안 쓴다" 가 구분이 안 됐다.  이 판은 셋을 따로 센다.
--
--     $E41F  루틴 진입 (PHA)        -- 아예 불리기는 하는가
--     $E424  우리 훅 자리 (STA $0000)
--     $E42B  STX $0003             -- 여기서 X 를 잰다
--
-- 그리고 180 프레임마다 **심박**을 찍는다.  0 이면 그 장면이 래스터 분할을
-- 안 쓰는 것이다 (그림 창이 있는 장면에서 다시 볼 것).
--
-- ⚠ 0.4.6.72 에 올린다.  훅이 없는 판이라야 **원래** X 가 보인다.
--   (0.4.6.76 에 올리면 우리 LDX #$00 뒤의 값이라 늘 0 이다 -- 근거가 안 된다)
--
-- 산출물  C:/snatcher/dump/rcr_x_hb_0_5_164_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/rcr_x_hb_0_5_164_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tsite\tline\trcr_lo\trcr_x\n')

local function say(m) emu.log(m); print(m) end

local KEYS = nil
local function keys(s)
  if KEYS then return KEYS end
  local function pick(c) for _, k in ipairs(c) do if type(s[k]) == 'number' then return k end end end
  KEYS = { line = pick({'vdc.scanline'}), x = pick({'cpu.x','x'}), a = pick({'cpu.a','a'}) }
  local names = {}
  for k, v in pairs(s) do if type(v) == 'number' then names[#names+1] = k end end
  table.sort(names)
  say(('  키: line=%s x=%s a=%s'):format(tostring(KEYS.line), tostring(KEYS.x), tostring(KEYS.a)))
  if not KEYS.x then say('  ⚠ X 키를 못 찾았다.  전체 키: ' .. table.concat(names, ' ')) end
  return KEYS
end

local frame = 0
local hit = { e41f = 0, e424 = 0, e42b = 0 }
local seen, bad = {}, 0

local function probe(site)
  return function()
    hit[site] = hit[site] + 1
    if site ~= 'e42b' then return end
    local ok, s = pcall(emu.getState); if not ok or not s then return end
    local K = keys(s)
    local x  = K.x and s[K.x] or -1
    local lo = K.a and s[K.a] or -1
    local ln = K.line and s[K.line] or -1
    local key = ('%d/%d'):format(lo, x)
    seen[key] = (seen[key] or 0) + 1
    if x ~= 0 then
      bad = bad + 1
      if bad <= 10 then
        say(('★X≠0  f%-7d line=%-3d RCR lo=%d X=%d  <- LDX #$00 이 틀렸다'):format(frame, ln, lo, x))
      end
    end
    if seen[key] == 1 then
      say(('  새 조합  RCR lo=%-4d X=%-3d  (line %d)'):format(lo, x, ln))
      out:write(('%d\tE42B\t%d\t%d\t%d\n'):format(frame, ln, lo, x))
      out:flush()
    end
  end
end

emu.addMemoryCallback(probe('e41f'), emu.callbackType.exec, 0xE41F, 0xE420, CPU, MEM)
emu.addMemoryCallback(probe('e424'), emu.callbackType.exec, 0xE424, 0xE426, CPU, MEM)
emu.addMemoryCallback(probe('e42b'), emu.callbackType.exec, 0xE42B, 0xE42D, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  if frame % 180 == 0 then
    say(('  심박 f%-7d  $E41F %d · $E424 %d · $E42B %d')
          :format(frame, hit.e41f, hit.e424, hit.e42b))
    if hit.e41f == 0 and frame >= 540 then
      say('  ★ 루틴 자체가 한 번도 안 불렸다 -- 이 장면은 래스터 분할을 안 쓴다.')
      say('    그림 창이 나오는 장면(국장실 등)으로 가서 다시 볼 것.')
    end
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  local parts = {}
  for k, n in pairs(seen) do parts[#parts+1] = ('%s x%d'):format(k, n) end
  out:write(('# E41F %d · E424 %d · E42B %d · X!=0 %d\n'):format(
    hit.e41f, hit.e424, hit.e42b, bad))
  out:close()
  say(('끝 -- $E41F %d · $E424 %d · $E42B %d'):format(hit.e41f, hit.e424, hit.e42b))
  say('     RCR lo/X 조합: ' .. (next(seen) and table.concat(parts, ' · ') or '(없음)'))
  say(('     X != 0 은 %d 회'):format(bad))
end, emu.eventType.scriptEnded)

say('SUB 0.5.164-rcr-x-hb armed -- 순수 관측 (0.4.6.72 에 올릴 것)')
say('  180 프레임마다 심박을 찍는다.  전부 0 이면 이 장면이 분할을 안 쓰는 것이다')
say('  ' .. PATH)
