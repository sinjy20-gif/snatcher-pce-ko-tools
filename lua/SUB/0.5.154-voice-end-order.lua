-- SUB 0.5.154 -- 음성 끝 프레임에 누가 어느 순서로 도는가
--
-- ★ 순수 관측.  아무것도 안 고친다.  게임 무수정.
--
-- 0.5.153 이 확정한 것
-- ---------------------------------------------------------------------------
--     helper=true  복원 스캔라인 55..198 (2451 회) · 비우기 41 (192 회)
--
-- SAT 는 vblank 에 래치되므로 라인 41 의 비우기는 **이번 프레임에 효과가 없다.**
-- 라인 55 부터 복원이 글리프 자리를 배경으로 덮고, 그 아래 스캔라인의
-- 스프라이트가 그것을 그린다 -> 화면 중간부터 알록달록한 띠.
--
-- 고치려면 비우기와 복원을 **한 프레임 벌려야** 한다.  상주부(Track02)는 감사
-- 불변식이라 못 건드리고, 헬퍼는 음성 끝에 한 번만 불린다.  그러니 벌리는 것은
-- 뱅크1 armer 쪽 일이다.  **그런데 어디에 끼울지는 순서를 알아야 정해진다.**
--
-- 무엇을 재나 -- 프레임 안 사건 순서
-- ---------------------------------------------------------------------------
--     $FEC4        상주부 -> 뱅크1 판정 (armer/scheduler 가 여기서 돈다)
--     $5B83 entry  지금 $5B80 에 올라온 것의 진입   (helper/engine 을 가려 적는다)
--     $5CC8 push   렌더러가 스프라이트를 미는 자리
--     $5C48 wipe   헬퍼의 SATB 비우기
--     $5C1F rest   헬퍼의 VRAM 복원  (렌더러 glyph_loop 도 여기를 지난다)
--     $7FDF 쓰기   state 가 언제·어디서 바뀌는가 (PC 같이)
--
-- 복원이 일어난 프레임을 중심으로 **앞 3 · 뒤 2 프레임**을 통째로 뱉는다.
--
-- 판정에 쓸 것
--     복원 프레임에 push 가 있었나        -> 있으면 그 프레임 스프라이트가 살아 있다
--     state 3 이 언제 써지나 · 누가 쓰나  -> armer 를 어디서 붙잡을지가 정해진다
--     entry 가 helper 로 바뀌는 시점      -> 엔진이 언제 헐리는가
--
-- 산출물  C:/snatcher/dump/voice_end_order_0_5_154_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local VRAM = emu.memType.pceVideoRam

local ENGINE = 0x5B80
local A_ENTRY   = 0x5B83
local A_PUSH    = 0x5CC8      -- push +328
local A_WIPE    = 0x5C48      -- helper wipe_loop +200
local A_RESTORE = 0x5C1F      -- helper restore_loop +159
local FEC4      = 0xFEC4
local STATE_ADDR = 0x7FDF
local SATB, SLOTS = 0x1000, 64

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/voice_end_order_0_5_154_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\trel\tstate\tsprites\tevents\n')

local function say(m) emu.log(m); print(m) end
local function rd(a) local ok,v = pcall(emu.read, a, MEM); return (ok and type(v)=='number') and v or -1 end
local function rb(a) local ok,v = pcall(emu.read, a, VRAM); return (ok and type(v)=='number') and v or 0 end
local function rw(word) local at = word*2; return rb(at) | (rb(at+1) << 8) end

local function line()
  local ok, s = pcall(emu.getState)
  if not ok or not s then return -1 end
  local v = s['vdc.scanline']
  return type(v) == 'number' and math.floor(v) or -1
end

local PCK = nil
local function pcNow()
  local ok, s = pcall(emu.getState)
  if not ok or not s then return -1 end
  if PCK == nil then
    PCK = false
    for _, k in ipairs({'cpu.pc', 'pc'}) do
      if type(s[k]) == 'number' then PCK = k break end
    end
  end
  if PCK == false then return -1 end
  local v = s[PCK]
  return type(v) == 'number' and math.floor(v) or -1
end

-- 지금 $5B80 에 올라온 것이 헬퍼인가 (entry 오퍼랜드로 가린다)
local function helperUp()
  return rd(ENGINE + 4) == 0x30 and rd(ENGINE + 5) == 0x5D
end

local ev, seen = {}, {}
local function mark(tag, once)
  if once then
    if seen[tag] then
      seen[tag] = seen[tag] + 1
      return
    end
    seen[tag] = 1
  end
  ev[#ev+1] = ('%s@%d'):format(tag, line())
end

emu.addMemoryCallback(function() mark('FEC4', true) end,
  emu.callbackType.exec, FEC4, FEC4 + 2, CPU, MEM)
emu.addMemoryCallback(function()
  mark(helperUp() and 'ENTRY(H)' or 'ENTRY(E)', true)
end, emu.callbackType.exec, A_ENTRY, A_ENTRY + 2, CPU, MEM)
emu.addMemoryCallback(function() mark('PUSH', true) end,
  emu.callbackType.exec, A_PUSH, A_PUSH + 2, CPU, MEM)
emu.addMemoryCallback(function()
  mark(helperUp() and 'WIPE' or 'e.wipe', true)
end, emu.callbackType.exec, A_WIPE, A_WIPE + 2, CPU, MEM)
emu.addMemoryCallback(function()
  mark(helperUp() and 'RESTORE' or 'e.glyph', true)
end, emu.callbackType.exec, A_RESTORE, A_RESTORE + 2, CPU, MEM)
emu.addMemoryCallback(function(address, value)
  ev[#ev+1] = ('ST=%02X@%d(pc=%04X)'):format((value or 0) & 0xFF, line(), pcNow())
end, emu.callbackType.write, STATE_ADDR, STATE_ADDR, CPU, MEM)

local function sprites()
  local n = 0
  for i = 0, SLOTS-1 do
    if (rw(SATB + i*4 + 2) & 0x07FF) ~= 0 then n = n + 1 end
  end
  return n
end

local frame, ring, RING = 0, {}, 4
local pending = 0

emu.addEventCallback(function()
  frame = frame + 1
  local row = { f = frame, state = rd(STATE_ADDR), spr = sprites(),
                ev = table.concat(ev, ' '), rest = (seen['RESTORE'] or 0) }
  -- 복원 횟수도 붙인다
  if row.rest > 0 then row.ev = row.ev .. (' [RESTORE x%d]'):format(row.rest) end

  ring[#ring+1] = row
  if #ring > RING then table.remove(ring, 1) end

  if row.rest > 0 then
    say(('=== 음성 끝 f%d -- 앞 %d 프레임부터 ==='):format(frame, #ring - 1))
    for i, r in ipairs(ring) do
      local rel = i - #ring
      say(('  f%-7d rel%+d  state=%-3d spr=%-2d  %s'):format(r.f, rel, r.state, r.spr, r.ev))
      out:write(('%d\t%d\t%d\t%d\t%s\n'):format(r.f, rel, r.state, r.spr, r.ev))
    end
    out:flush()
    pending = 2
  elseif pending > 0 then
    pending = pending - 1
    say(('  f%-7d rel+%d  state=%-3d spr=%-2d  %s'):format(row.f, 2 - pending, row.state, row.spr, row.ev))
    out:write(('%d\t%d\t%d\t%d\t%s\n'):format(row.f, 2 - pending, row.state, row.spr, row.ev))
    out:flush()
  end

  ev, seen = {}, {}
end, emu.eventType.endFrame)

emu.addEventCallback(function() out:close() end, emu.eventType.scriptEnded)

say('SUB 0.5.154-voice-end-order armed -- 순수 관측')
say('  ★ 복원이 일어난 프레임을 중심으로 앞 3 · 뒤 2 프레임을 통째로 뱉는다')
say('  볼 것: 복원 프레임에 PUSH 가 있었나 · state 3 을 누가 언제 쓰나')
say('  ' .. PATH)
