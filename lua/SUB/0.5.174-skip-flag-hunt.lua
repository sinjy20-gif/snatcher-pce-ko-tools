-- SUB 0.5.174 -- 스킵을 알려주는 **RAM 깃발** 찾기
--
-- ★ 순수 관측.  아무것도 안 쓴다.  화면에도 아무것도 안 그린다.
--
-- 왜
-- --
-- 0.5.173 실측:
--
--     f8163  스킵 누름
--     +4     $E018 (CD_PAUSE)          ← 빠르지만 BIOS 점프표 훅이 필요하다
--     +620   $20A2 $17 -> $00          ← 지금 쓰는 신호.  10.3 초 늦다
--
-- 그 10 초 동안 자막이 2~3 개 더 뜬다.  스케줄러는 **메모리만 읽을 수 있으니**
-- BIOS 호출은 못 본다.  그래서 "누른 직후 바뀌어서 계속 유지되는 RAM 바이트"
-- 를 찾는다.  있으면 스케줄러가 5 바이트로 읽고 끝난다.
--
-- 어떻게 찾나
-- -----------
--     1  트랙 17 재생 중       30 프레임마다 훑어 **변덕스러운 주소를 표시**한다
--                              (재생 중 이미 계속 변하는 것은 깃발이 못 된다)
--     2  스킵 누른 순간         $2000-$3FFF 를 통째로 스냅샷
--     3  누른 뒤 120 프레임     매 프레임 비교 (여기서 바뀌는 게 후보)
--        그 뒤                  10 프레임마다 비교 (계속 유지되는지 본다)
--     4  끝날 때               "안 변덕스럽고 · 누른 직후 바뀌고 · 끝까지 유지"
--                              인 주소만 뽑는다
--
-- 판정
-- ----
--     후보가 나오면      그 주소를 스케줄러가 읽으면 된다.  $E018 훅이 필요 없다
--     안 나오면          선택은 둘 -- $E018 훅을 감수하거나 자막 2 개를 감수하거나
--
-- ⚠ 8 KB 를 프레임마다 훑으므로 그 구간에서 에뮬이 느려진다.  정상이다.
--
-- 산출물  C:/snatcher/dump/skip_flag_0_5_174_<시각>.tsv

local MEM = emu.memType.pceMemory

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/skip_flag_0_5_174_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('addr\tbefore\tafter\tfirst_delta\tstable\n')

local function say(m) emu.log(m); print(m) end

local LO, HI = 0x2000, 0x3FFF
local TRACK_AT, TRACK_BCD = 0x20A2, 0x17
local FINE, FINE_FRAMES = 1, 120      -- 누른 뒤 이만큼은 매 프레임
local COARSE = 10                     -- 그 뒤는 이 간격
local SCAN_EVERY = 30                 -- 누르기 전 변덕 조사 간격

local frame = 0
local playing = false
local pressedAt = nil

local volatile = {}       -- 재생 중에 한 번이라도 변한 주소 -> 깃발 후보에서 뺀다
local prevScan = nil      -- 재생 중 직전 스냅샷
local snap = nil          -- 누른 순간 스냅샷
local firstDelta = {}     -- 주소 -> 누른 뒤 처음 달라진 프레임(상대)
local lastVal = {}        -- 주소 -> 마지막으로 본 값
local heldBefore = ''

local function scan()
  local t = {}
  for a = LO, HI do t[a] = emu.read(a, MEM, false) or 0 end
  return t
end

local function padHeld()
  local ok, s = pcall(emu.getInput, 0)
  if not ok or type(s) ~= 'table' then return nil end
  local parts = {}
  for k, v in pairs(s) do if v == true then parts[#parts + 1] = tostring(k) end end
  table.sort(parts)
  return table.concat(parts, '+')
end

emu.addEventCallback(function()
  frame = frame + 1
  local trk = emu.read(TRACK_AT, MEM, false) or 0

  -- ---- 재생 중: 변덕 조사 -------------------------------------------
  if not pressedAt then
    if trk == TRACK_BCD then
      if not playing then
        playing = true
        say(('트랙 17 재생 시작 f%d -- 변덕 조사 시작'):format(frame))
      end
      if frame % SCAN_EVERY == 0 then
        local now = scan()
        if prevScan then
          local n = 0
          for a = LO, HI do
            if now[a] ~= prevScan[a] then volatile[a] = true; n = n + 1 end
          end
          if frame % 600 == 0 then
            local vc = 0
            for _ in pairs(volatile) do vc = vc + 1 end
            say(('  f%-7d 이번 창에서 변한 곳 %d · 누적 변덕 %d / %d')
                  :format(frame, n, vc, HI - LO + 1))
          end
        end
        prevScan = now
      end
      -- 스킵 눌렸나
      local held = padHeld()
      if held and held ~= heldBefore then
        if held ~= '' then
          pressedAt = frame
          snap = scan()
          for a = LO, HI do lastVal[a] = snap[a] end
          local vc = 0
          for _ in pairs(volatile) do vc = vc + 1 end
          say(('★스킵 누름 f%d (%s) -- 스냅샷.  변덕 제외 %d 곳')
                :format(frame, held, vc))
        end
        heldBefore = held or ''
      end
    end
    return
  end

  -- ---- 누른 뒤: 비교 -------------------------------------------------
  local since = frame - pressedAt
  local step = (since <= FINE_FRAMES) and FINE or COARSE
  if since % step ~= 0 then return end

  local found = 0
  for a = LO, HI do
    local v = emu.read(a, MEM, false) or 0
    if v ~= lastVal[a] then
      lastVal[a] = v
      if not volatile[a] and not firstDelta[a] then
        firstDelta[a] = since
        found = found + 1
      end
    end
  end
  if found > 0 and since <= FINE_FRAMES then
    say(('  +%-4d 새 후보 %d 곳'):format(since, found))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  say('')
  if not pressedAt then
    say('★스킵이 안 잡혔다 -- 트랙 17 재생 중에 눌렀는지 확인할 것')
    out:close(); say('  ' .. PATH); return
  end

  -- 끝까지 유지된 것만 남긴다
  local rows = {}
  for a, d in pairs(firstDelta) do
    local now = emu.read(a, MEM, false) or 0
    rows[#rows + 1] = { a = a, before = snap[a], after = now, d = d,
                        stable = (now ~= snap[a]) }
  end
  table.sort(rows, function(x, y)
    if x.d ~= y.d then return x.d < y.d end
    return x.a < y.a
  end)

  local keep = {}
  for _, r in ipairs(rows) do if r.stable then keep[#keep + 1] = r end end

  say(('스킵 f%d -- 변덕 아닌 주소 중 누른 뒤 바뀐 것 %d 곳 · 끝까지 유지 %d 곳')
        :format(pressedAt, #rows, #keep))
  say('')
  say('빠른 순서 (끝까지 유지된 것만, 앞 40)')
  for i = 1, math.min(#keep, 40) do
    local r = keep[i]
    local line = ('  +%-4d  $%04X  $%02X -> $%02X'):format(r.d, r.a, r.before, r.after)
    say(line)
  end
  for _, r in ipairs(rows) do
    out:write(('%04X\t%02X\t%02X\t%d\t%s\n')
                :format(r.a, r.before, r.after, r.d, r.stable and 'Y' or 'N'))
  end
  out:close()
  say('')
  say('  읽는 법: +값이 작고 끝까지 유지되는 주소가 곧 스킵 깃발이다.')
  say('           $20A2 는 +620 이었다 -- 그보다 훨씬 작아야 값어치가 있다.')
  say('  ' .. PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.174-skip-flag-hunt armed -- 순수 관측')
say('  오프닝 재생 -> 자막 3~4 개 -> ★스킵 -> 10 초 더 -> 스크립트 정지')
say('  ⚠ 스킵 직후 2 초간 8 KB 를 매 프레임 훑는다.  느려지는 것은 정상')
say('  ' .. PATH)
