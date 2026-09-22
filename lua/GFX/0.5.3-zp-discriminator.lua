-- GFX 0.5.3 -- 덩어리를 가르는 제로페이지 바이트 찾기  ★순수 관측 · 쓰기 0 B
--
-- 여기까지 (2026-09-09)
-- ---------------------------------------------------------------------------
--   0.5.0  tick(프레임 1회)은 $3B00 지문을 못 본다          프레임 경계 일치 0
--   0.5.1  헌사 = 무장후 1590 프레임 · 그 프레임에 호출 680 · 지문 16
--          덩어리 폭 약 3 프레임 · 지문은 그 중 한 프레임에만
--          ⚠ 무장후 값이 1588 / 1588 / 1590 -- 2 프레임 흔들린다
--   0.5.2  CD 읽기는 #239(f4874, 위치 $03:$5A)에서 **끝난다**.
--          그 뒤로 덩어리가 셋 더 나온다 = 파란화면·RSS·헌사가 **읽기 하나**에서 나온다
--          -> CD 위치로는 화면을 못 가른다 (A 안 후보 하나 사망)
--          ★ 다만 $03:$5A 는 주행 내내 유일 -- 무장 신호는 확정
--          ★ CD_READ 파라미터가 $20F8-$20FF 에 통째로 있다 = 게임 상태가 제로페이지에 산다
--
-- 그래서 이걸 잰다
-- ---------------------------------------------------------------------------
--   화면을 가르는 값이 CD 쪽에 없다면 **제로페이지 어딘가**에 있을 것이다.
--   그리고 제로페이지는 tick 이 **프레임마다 읽을 수 있는 자리**다.
--
--   덩어리마다 $2000-$20FF 256 B 를 통째로 뜨고, 헌사 덩어리에서만 나오는
--   바이트 자리를 **스크립트가 직접 골라서** 찍어 준다.
--
-- 무엇을 하나
--   1) `$725C` 로 덩어리를 나눈다 · 호출 시점 지문으로 헌사를 표시한다
--   2) 덩어리 **첫 호출**에 제로페이지 256 B 스냅샷
--   3) 덩어리가 도는 **프레임 경계**마다도 스냅샷 (tick 이 보는 시점)
--   4) 끝날 때:
--        a. 헌사 값이 **다른 모든 덩어리와 다른** 자리를 고른다   <- 후보
--        b. 그 자리가 **프레임 경계에서도 같은 값**인지 확인한다  <- tick 이 쓸 수 있나
--
-- 판정
--   후보가 있고 프레임 경계에서도 유지된다  -> ★그 자리가 신원.  설계 끝
--   후보는 있는데 프레임 경계에서 흔들린다  -> 호출 단위 신호.  못 쓴다
--   후보가 없다                             -> 제로페이지 밖.  창을 넓혀 다시
--
-- 쓰는 법  이것만 로드 · 부팅 -> 헌사 지나서 조금 더 · Stop
-- 산출물   C:/snatcher/dump/gfxzp_0_5_3_<시각>_zp.tsv / _summary.txt

local BUF  = 0x3B00
local CALL = 0x725C
local ZP0, ZPN   = 0x2000, 256
local GAP_FRAMES = 10
local MAX_FRAME_SNAP = 8        -- 덩어리당 프레임 스냅샷 상한

local SIG = { 0x80,0x00,0x40,0x00,0x20,0x00,0x10,0x00,
              0x08,0x00,0x04,0x00,0x03,0x00,0xFC,0x00 }

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local STAMP = os.date('%Y%m%d_%H%M%S')
local BASE  = 'C:/snatcher/dump/gfxzp_0_5_3_' .. STAMP

local function say(m) emu.log(m); print(m) end
local function rd(a)
  local ok, v = pcall(emu.read, a, MEM)
  return (ok and type(v) == 'number') and v or -1
end

local function zpSnap()
  local t = {}
  for i = 1, ZPN do t[i] = rd(ZP0 + i - 1) end
  return t
end

local function callerPC()
  local ok, s = pcall(emu.getState)
  if not ok or type(s) ~= 'table' then return -1 end
  local sp = s['cpu.sp'] or s['sp'] or s['cpu.spl']
  if type(sp) ~= 'number' then return -1 end
  local lo = rd(0x2100 + ((sp + 1) % 0x100))
  local hi = rd(0x2100 + ((sp + 2) % 0x100))
  if lo < 0 or hi < 0 then return -1 end
  return (hi * 256 + lo) - 2
end

local frame  = 0
local bursts = {}
local cur, lastCall = nil, -999
local hadCallThisFrame = false

emu.addMemoryCallback(function()
  if cur == nil or (frame - lastCall) > GAP_FRAMES then
    cur = { n = #bursts + 1, f0 = frame, f1 = frame, calls = 0, hits = 0,
            caller = callerPC(), zp = zpSnap(), fsnap = {} }
    bursts[#bursts + 1] = cur
    say(('  덩어리 %d 시작  f%d  호출자 $%04X'):format(cur.n, frame, cur.caller))
  end
  lastCall  = frame
  cur.f1    = frame
  cur.calls = cur.calls + 1
  hadCallThisFrame = true

  local ok = true
  for i = 1, #SIG do
    if rd(BUF + i - 1) ~= SIG[i] then ok = false; break end
  end
  if ok then cur.hits = cur.hits + 1 end
end, emu.callbackType.exec, CALL, CALL, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  if hadCallThisFrame and cur and #cur.fsnap < MAX_FRAME_SNAP then
    cur.fsnap[#cur.fsnap + 1] = { f = frame, zp = zpSnap() }
  end
  hadCallThisFrame = false
  if frame % 600 == 0 then
    say(('f%d  덩어리 %d'):format(frame, #bursts))
  end
end, emu.eventType.endFrame)

-- ---------------------------------------------------------------- 마무리
emu.addEventCallback(function()
  local fz = assert(io.open(BASE .. '_zp.tsv', 'w'))
  fz:write('burst\tkind\tframe\tcalls\tsig\tcaller\tzp\n')
  local function line(b, kind, f, t)
    local h = {}
    for i = 1, ZPN do h[i] = ('%02X'):format(t[i]) end
    fz:write(('%d\t%s\t%d\t%d\t%d\t$%04X\t%s\n'):format(
      b.n, kind, f, b.calls, b.hits, b.caller, table.concat(h, ' ')))
  end
  for _, b in ipairs(bursts) do
    line(b, 'start', b.f0, b.zp)
    for _, s in ipairs(b.fsnap) do line(b, 'frame', s.f, s.zp) end
  end
  fz:close()

  local s = assert(io.open(BASE .. '_summary.txt', 'w'))
  local function put(m) s:write(m .. '\n'); say(m) end

  put(('프레임 %d · 덩어리 %d'):format(frame, #bursts))
  put('')
  put(' #   프레임범위      폭   호출수   지문  호출자')
  put(' -------------------------------------------------')
  for _, b in ipairs(bursts) do
    put(('%2d  f%-6d..f%-6d %3d  %6d  %5d  $%04X%s'):format(
      b.n, b.f0, b.f1, b.f1 - b.f0 + 1, b.calls, b.hits, b.caller,
      b.hits > 0 and '   ★헌사' or ''))
  end
  put('')

  local ded = nil
  for _, b in ipairs(bursts) do if b.hits > 0 then ded = b; break end end
  if not ded then
    put('⚠ 지문이 한 번도 안 맞았다 -- 헌사를 안 지났다')
    s:close(); return
  end
  if #bursts < 2 then
    put('⚠ 덩어리가 하나뿐이라 비교할 게 없다')
    s:close(); return
  end

  -- (a) 헌사에만 있는 값
  local cand = {}
  for i = 1, ZPN do
    local v, uniq = ded.zp[i], true
    for _, b in ipairs(bursts) do
      if b ~= ded and b.zp[i] == v then uniq = false; break end
    end
    if uniq then cand[#cand + 1] = i end
  end

  put(('★ 헌사에만 있는 제로페이지 자리: %d 개'):format(#cand))
  if #cand == 0 then
    put('  제로페이지 밖이다 -- 창을 넓혀 다시 재야 한다 ($2100-$3FFF)')
    s:close(); return
  end

  -- (b) 프레임 경계에서도 유지되나
  put('')
  put(' 주소    값   프레임경계 유지   다른 덩어리 값들')
  put(' ---------------------------------------------------------------')
  local solid = {}
  for _, i in ipairs(cand) do
    local v = ded.zp[i]
    local keep, total = 0, #ded.fsnap
    for _, sn in ipairs(ded.fsnap) do
      if sn.zp[i] == v then keep = keep + 1 end
    end
    local others = {}
    for _, b in ipairs(bursts) do
      if b ~= ded then others[#others + 1] = ('%02X'):format(b.zp[i]) end
    end
    local ok = (total > 0 and keep == total)
    if ok then solid[#solid + 1] = i end
    put((' $%04X  %02X   %d/%d %s   %s'):format(
      ZP0 + i - 1, v, keep, total, ok and '★' or ' ',
      table.concat(others, ' ')))
  end

  put('')
  if #solid > 0 then
    local names = {}
    for _, i in ipairs(solid) do
      names[#names + 1] = ('$%04X=%02X'):format(ZP0 + i - 1, ded.zp[i])
    end
    put(('★★ 프레임 경계에서도 유지되는 자리 %d 개 -- **tick 이 쓸 수 있다**'):format(#solid))
    put('   ' .. table.concat(names, ' · '))
    put('   ⚠ 다음 주행에서 같은 값이 나오는지 한 번 더 확인할 것 (재현성)')
  else
    put('⚠ 후보는 있는데 프레임 경계에서 전부 흔들린다 -- 호출 단위 신호다')
    put('  타이밍(무장+약1590)으로 가되 앞뒤 여유를 두는 설계로 내려가야 한다')
  end
  s:close()
  say('  ' .. BASE .. '_summary.txt')
end, emu.eventType.scriptEnded)

say('GFX 0.5.3-zp-discriminator armed -- 덩어리별 제로페이지 256 B · 쓰기 0 B')
say('  부팅 -> 헌사 지나서 조금 더 · Stop')
say('  ' .. BASE .. '_zp.tsv')
