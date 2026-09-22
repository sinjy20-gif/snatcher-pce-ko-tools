-- GFX 0.5.2 -- CD_READ 를 전수로 찍는다 (화면마다 위치가 다른가)  ★순수 관측 · 쓰기 0 B
--
-- 여기까지 온 경위 (2026-09-09)
-- ---------------------------------------------------------------------------
--   0.5.0  tick(프레임 1회)은 $3B00 지문을 못 본다        프레임 경계 일치 0
--   0.5.1  헌사 = 무장후 1590 프레임 · 그 프레임에 호출 680 · 지문 16
--          -> 덩어리는 약 3 프레임 폭 · 지문은 그 중 한 프레임에만
--          -> 지문은 **호출 단위 신호** 확정
--          -> 그런데 무장후 값이 1588 / 1588 / **1590** 으로 2 프레임 흔들린다
--             덩어리 폭 3 프레임에 오차 2 = 순수 타이밍은 아슬아슬하다
--
-- 그래서 이걸 잰다
-- ---------------------------------------------------------------------------
--   무장 신호가 `CD_READ($E009)` + 제로페이지 위치 `$20FD:$20FE = $03:$5A` 였다.
--   = 게임은 CD 를 읽을 때마다 **위치 필드를 세팅한다**.
--
--   ★ 화면마다 자기 그림을 따로 읽는다면 **화면마다 그 값이 다르다.**
--     그러면 프레임 세기도 지문도 필요 없다 --
--     헌사 그림을 읽는 그 CD_READ 자체가 신원이 된다.
--     BIOS 호출이라 MPR7 도 우리 것이다 (뱅크 문제 없음).
--
--   지금은 `$03:$5A` 하나만 보고 있어서 나머지를 모른다.  전수로 찍는다.
--
-- 무엇을 하나
--   1) `$E009` 진입마다 제로페이지 $20F8-$20FF 16 B 와 호출자·프레임을 남긴다
--   2) `$725C` 로 덩어리를 나누고 호출 시점 지문으로 헌사를 찍는다
--   3) 덩어리마다 **직전 CD_READ 가 몇 번째였고 위치가 뭐였는지** 짝지어 준다
--
-- 판정
--   헌사 직전 CD_READ 의 위치가 주행 내내 유일하다   -> ★그게 신원.  설계 끝
--   그림들이 CD_READ 한 번에 뭉쳐 들어온다           -> 위치로는 못 가른다
--                                                      (그 경우 읽기 순번+타이밍)
--
-- 쓰는 법  이것만 로드 · 부팅 -> 헌사 지나서 조금 더 · Stop
-- 산출물   C:/snatcher/dump/gfxcd_0_5_2_<시각>_reads.tsv / _bursts.tsv / _summary.txt

local BUF     = 0x3B00
local CALL    = 0x725C          -- Track02 업로더 진입
local CD_READ = 0xE009
local ZP0, ZPN = 0x20F8, 16     -- 제로페이지 파라미터 창 (HuC6280 zp = $2000-$20FF)
local GAP_FRAMES = 10

local SIG = { 0x80,0x00,0x40,0x00,0x20,0x00,0x10,0x00,
              0x08,0x00,0x04,0x00,0x03,0x00,0xFC,0x00 }

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local STAMP = os.date('%Y%m%d_%H%M%S')
local BASE  = 'C:/snatcher/dump/gfxcd_0_5_2_' .. STAMP

local fR = assert(io.open(BASE .. '_reads.tsv', 'w'))
fR:write('n\tframe\tcaller\tzp_F8_FF\n')
fR:flush()

local function say(m) emu.log(m); print(m) end
local function rd(a)
  local ok, v = pcall(emu.read, a, MEM)
  return (ok and type(v) == 'number') and v or -1
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
local reads  = {}       -- 전수 기록
local bursts = {}
local cur, lastCall = nil, -999

-- ------------------------------------------------------------- CD_READ 전수
emu.addMemoryCallback(function()
  local zp = {}
  for i = 0, ZPN - 1 do zp[#zp + 1] = ('%02X'):format(rd(ZP0 + i)) end
  local r = { n = #reads + 1, frame = frame, caller = callerPC(),
              zp = table.concat(zp, ' '),
              pos = ('%02X:%02X'):format(rd(0x20FD), rd(0x20FE)) }
  reads[#reads + 1] = r
  fR:write(('%d\t%d\t$%04X\t%s\n'):format(r.n, r.frame, r.caller, r.zp))
  fR:flush()
end, emu.callbackType.exec, CD_READ, CD_READ, CPU, MEM)

-- ------------------------------------------------------------- 업로더
emu.addMemoryCallback(function()
  if cur == nil or (frame - lastCall) > GAP_FRAMES then
    cur = { f0 = frame, f1 = frame, calls = 0, hits = 0,
            caller = callerPC(), readN = #reads,
            pos = (#reads > 0) and reads[#reads].pos or '--' }
    bursts[#bursts + 1] = cur
  end
  lastCall  = frame
  cur.f1    = frame
  cur.calls = cur.calls + 1

  local ok = true
  for i = 1, #SIG do
    if rd(BUF + i - 1) ~= SIG[i] then ok = false; break end
  end
  if ok then cur.hits = cur.hits + 1 end
end, emu.callbackType.exec, CALL, CALL, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  if frame % 600 == 0 then
    say(('f%d  CD읽기 %d · 덩어리 %d'):format(frame, #reads, #bursts))
  end
end, emu.eventType.endFrame)

-- ------------------------------------------------------------- 마무리
emu.addEventCallback(function()
  fR:close()

  local fB = assert(io.open(BASE .. '_bursts.tsv', 'w'))
  fB:write('n\tf0\tf1\tframes\tcalls\tsig\tcaller\tprev_read\tprev_pos\n')
  for i, b in ipairs(bursts) do
    fB:write(('%d\t%d\t%d\t%d\t%d\t%d\t$%04X\t%d\t%s\n'):format(
      i, b.f0, b.f1, b.f1 - b.f0 + 1, b.calls, b.hits, b.caller, b.readN, b.pos))
  end
  fB:close()

  local s = assert(io.open(BASE .. '_summary.txt', 'w'))
  local function put(m) s:write(m .. '\n'); say(m) end

  put(('프레임 %d · CD읽기 %d · 덩어리 %d'):format(frame, #reads, #bursts))
  put('')
  put(' #   프레임범위      폭   호출수   지문  호출자  직전읽기  위치')
  put(' ------------------------------------------------------------------')
  for i, b in ipairs(bursts) do
    put(('%2d  f%-6d..f%-6d %3d  %6d  %5d  $%04X  #%-5d  %s%s'):format(
      i, b.f0, b.f1, b.f1 - b.f0 + 1, b.calls, b.hits, b.caller,
      b.readN, b.pos, b.hits > 0 and '   ★헌사' or ''))
  end
  put('')

  -- 위치값이 몇 번씩 나왔나
  local cnt, order = {}, {}
  for _, r in ipairs(reads) do
    if cnt[r.pos] == nil then cnt[r.pos] = 0; order[#order + 1] = r.pos end
    cnt[r.pos] = cnt[r.pos] + 1
  end
  put('CD읽기 위치값 빈도')
  for _, p in ipairs(order) do
    put(('   %s   %d 회%s'):format(p, cnt[p], cnt[p] == 1 and '   ← 유일' or ''))
  end
  put('')

  local ded = nil
  for _, b in ipairs(bursts) do if b.hits > 0 then ded = b; break end end
  if ded then
    put(('★ 헌사 덩어리 = f%d..f%d · 직전 CD읽기 #%d · 위치 %s'):format(
      ded.f0, ded.f1, ded.readN, ded.pos))
    if cnt[ded.pos] == 1 then
      put('★★ 그 위치값은 주행 내내 유일하다 -- **그게 신원이다.**')
      put('   프레임 세기도 지문도 필요 없다.  그 CD_READ 에서 바로 주입한다')
    else
      put(('⚠ 그 위치값이 %d 회 나온다 -- 위치만으론 못 가른다'):format(cnt[ded.pos]))
      put('   읽기 순번(#) 이 유일한지, zp 다른 칸이 갈리는지 reads.tsv 를 볼 것')
    end
  else
    put('⚠ 지문이 한 번도 안 맞았다 -- 헌사를 안 지났다')
  end
  s:close()
  say('  ' .. BASE .. '_summary.txt')
end, emu.eventType.scriptEnded)

say('GFX 0.5.2-cdread-census armed -- CD_READ 전수 + 덩어리 짝짓기 · 쓰기 0 B')
say('  부팅 -> 헌사 지나서 조금 더 · Stop')
say('  ' .. BASE .. '_reads.tsv')
