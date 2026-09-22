-- SUB 0.5.166 -- CD-DA 스케줄러 연동 검증 (0.4.7.2)
--
-- ★ 순수 관측.  아무것도 안 쓴다.  화면에도 아무것도 안 그린다.
--
-- 이 프로브는 **두 판에 다 올린다.**  같은 지표를 읽는 방향이 반대다:
--
--   0.4.7.1 (스케줄러 없음)   $ECF9 구간 접촉이 **0 이어야** 한다
--                             -> 그 자리를 써도 된다는 승격 근거
--   0.4.7.2 (스케줄러 있음)   $ECF9 exec 가 **프레임마다** 있어야 한다
--                             -> 스케줄러가 실제로 도는지
--
-- 무엇을 보나
-- -----------
--   1  뱅크1 $ECF9-$F04D 의 read / write / exec
--   2  AC $1FEB00 페이지를 여는가 (mini index 선적재 자리)
--   3  ★ 렌더러 즉치 3 개가 mini index 표와 일치하는가
--      -> TAI 직후 AC 자동증가 가정의 **직접 검증**이다.
--         틀리면 vram_hi/lo/attr 가 엉뚱한 바이트에서 읽혀 표와 안 맞는다
--   4  STATE($7FDF) 흐름
--
-- ⚠ 트랙 17(오프닝)을 끝까지 틀어야 39 구간이 다 지나간다.
--   그리고 승격 판정(1)은 오프닝만으로 부족하다 -- 대사·메뉴·장면전환도 볼 것.
--
-- 산출물  C:/snatcher/dump/cdda_sched_0_5_166_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/cdda_sched_0_5_166_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame	kind	detail\n')

local function say(m) emu.log(m); print(m) end

local SCHED_LO, SCHED_HI = 0xECF9, 0xF04D     -- 스케줄러를 심은 구간
local STATE_AT = 0x7FDF
local ENGINE   = 0x5B80
local OFF_HI, OFF_LO, OFF_AT = 200, 235, 240  -- 렌더러 안 vram 즉치 3 개
local OFF_PTR  = 324                          -- record_ptr 3 B
local AC_MINI_PAGE = 0x1FEB00

-- mini index 표 (build/cutscene_subs/cdda_track17_mini_index.bin 에서 생성)
local MINI = {
  {f=2189,hi=0x20,lo=0x00,at=0x9F,p=0x16613E},
  {f=2434,hi=0x20,lo=0x00,at=0x9F,p=0x166174},
  {f=2660,hi=0x20,lo=0x00,at=0x9F,p=0x1661A1},
  {f=2716,hi=0x27,lo=0x38,at=0x9F,p=0x1661B0},
  {f=2927,hi=0x27,lo=0x38,at=0x9F,p=0x1661E0},
  {f=2958,hi=0x27,lo=0x38,at=0x9F,p=0x1661EC},
  {f=3126,hi=0x27,lo=0x38,at=0x9F,p=0x166219},
  {f=3243,hi=0x63,lo=0x18,at=0xBF,p=0x16624F},
  {f=3331,hi=0x63,lo=0x18,at=0xBF,p=0x166285},
  {f=3497,hi=0x63,lo=0x18,at=0xBF,p=0x1662B5},
  {f=3662,hi=0x20,lo=0x00,at=0x9F,p=0x1662E2},
  {f=3842,hi=0x20,lo=0x00,at=0x9F,p=0x166312},
  {f=3926,hi=0x20,lo=0x00,at=0x9F,p=0x166330},
  {f=4010,hi=0x20,lo=0x00,at=0x9F,p=0x16634E},
  {f=4177,hi=0x20,lo=0x00,at=0x9F,p=0x166381},
  {f=4374,hi=0x20,lo=0x00,at=0x9F,p=0x1663B7},
  {f=4570,hi=0x20,lo=0x00,at=0x9F,p=0x1663E7},
  {f=4722,hi=0x20,lo=0x00,at=0x9F,p=0x166414},
  {f=4769,hi=0x20,lo=0x00,at=0x9F,p=0x166426},
  {f=4992,hi=0x20,lo=0x00,at=0x9F,p=0x166456},
  {f=5040,hi=0x20,lo=0x00,at=0x9F,p=0x166465},
  {f=5142,hi=0x28,lo=0x40,at=0x9F,p=0x166477},
  {f=5323,hi=0x31,lo=0x88,at=0x9F,p=0x1664AD},
  {f=5521,hi=0x31,lo=0x88,at=0x9F,p=0x1664DA},
  {f=5566,hi=0x31,lo=0x88,at=0x9F,p=0x1664E9},
  {f=5811,hi=0x72,lo=0x90,at=0xBF,p=0x166519},
  {f=5897,hi=0x72,lo=0x90,at=0xBF,p=0x16653D},
  {f=5957,hi=0x72,lo=0x90,at=0xBF,p=0x166558},
  {f=6047,hi=0x72,lo=0x90,at=0xBF,p=0x16657C},
  {f=6102,hi=0x72,lo=0x90,at=0xBF,p=0x166594},
  {f=6248,hi=0x27,lo=0x38,at=0x9F,p=0x1665B5},
  {f=6389,hi=0x27,lo=0x38,at=0x9F,p=0x1665E5},
  {f=6419,hi=0x27,lo=0x38,at=0x9F,p=0x1665F4},
  {f=6590,hi=0x2B,lo=0x58,at=0x9F,p=0x16661E},
  {f=6730,hi=0x2B,lo=0x58,at=0x9F,p=0x166645},
  {f=6844,hi=0x2B,lo=0x58,at=0x9F,p=0x166666},
  {f=6942,hi=0x2B,lo=0x58,at=0x9F,p=0x166684},
  {f=7042,hi=0x58,lo=0xC0,at=0xAF,p=0x1666A5},
  {f=7233,hi=0x58,lo=0xC0,at=0xAF,p=0x1666DB},
}

local frame = 0
local hit = { read = 0, write = 0, exec = 0 }
local seen_pc = {}
local acpage = {}
local last = nil
local step, okc, badc = 0, 0, 0

local function watch(kind)
  return function(addr)
    hit[kind] = hit[kind] + 1
    if kind == 'exec' then return end          -- exec 는 세기만 (프레임마다 온다)
    local ok, s = pcall(emu.getState)
    local pc = (ok and s and (s['cpu.pc'] or s.pc)) or -1
    local key = kind .. '/' .. tostring(pc)
    if not seen_pc[key] then
      seen_pc[key] = true
      say(('접촉  f%-7d %-5s $%04X  PC $%04X'):format(frame, kind, addr or 0, pc))
      out:write(('%d	%s	%s $%04X PC $%04X\n'):format(frame, kind, kind, addr or 0, pc))
      out:flush()
    end
  end
end

emu.addMemoryCallback(watch('read'),  emu.callbackType.read,  SCHED_LO, SCHED_HI, CPU, MEM)
emu.addMemoryCallback(watch('write'), emu.callbackType.write, SCHED_LO, SCHED_HI, CPU, MEM)
emu.addMemoryCallback(watch('exec'),  emu.callbackType.exec,  SCHED_LO, SCHED_HI, CPU, MEM)

-- AC 포트 base 래치를 디코드해 어떤 페이지를 여는지 센다
local acb = { [0] = {0,0,0}, [1] = {0,0,0} }
for port = 0, 1 do
  local p = 0x1A00 + port * 0x10
  for w = 1, 3 do
    emu.addMemoryCallback(function(_, value)
      acb[port][w] = value or 0
      if w == 3 then
        local a = acb[port][1] | (acb[port][2] << 8) | (acb[port][3] << 16)
        local pg = a & 0xFFFF00
        acpage[pg] = (acpage[pg] or 0) + 1
      end
    end, emu.callbackType.write, p + 1 + w, p + 1 + w, CPU, MEM)
  end
end

emu.addEventCallback(function()
  frame = frame + 1
  local st = emu.read(STATE_AT, MEM, false) or -1
  if st ~= 2 then return end

  local hi = emu.read(ENGINE + OFF_HI, MEM, false)
  local lo = emu.read(ENGINE + OFF_LO, MEM, false)
  local at = emu.read(ENGINE + OFF_AT, MEM, false)
  local p0 = emu.read(ENGINE + OFF_PTR,     MEM, false)
  local p1 = emu.read(ENGINE + OFF_PTR + 1, MEM, false)
  local p2 = emu.read(ENGINE + OFF_PTR + 2, MEM, false)
  local ptr = p0 | (p1 << 8) | (p2 << 16)
  local now = ('%02X/%02X/%02X/%06X'):format(hi, lo, at, ptr)
  if now == last then return end
  last = now

  step = step + 1
  local want = MINI[step]
  if want == nil then
    say(('★넘침  f%-7d 전환 %d 회째인데 표는 %d 개뿐  %s')
          :format(frame, step, #MINI, now))
    out:write(('%d	OVER	%s\n'):format(frame, now))
  elseif hi == want.hi and lo == want.lo and at == want.at and ptr == want.p then
    okc = okc + 1
    out:write(('%d	OK	#%d %s\n'):format(frame, step, now))
    if okc <= 5 or step == #MINI then
      say(('OK    f%-7d 구간 #%d  %s'):format(frame, step, now))
    end
  else
    badc = badc + 1
    say(('★불일치 f%-7d 구간 #%d'):format(frame, step))
    say(('        받음 %s'):format(now))
    say(('        기대 %02X/%02X/%02X/%06X'):format(want.hi, want.lo, want.at, want.p))
    say('        -> TAI 직후 AC 자동증가 가정이 틀렸을 수 있다')
    out:write(('%d	BAD	#%d got %s want %02X/%02X/%02X/%06X\n')
                :format(frame, step, now, want.hi, want.lo, want.at, want.p))
  end
  out:flush()
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if frame % 600 == 0 then
    say(('심박 f%-7d  $ECF9 exec %d · read %d · write %d   전환 %d (OK %d · 불일치 %d)')
          :format(frame, hit.exec, hit.read, hit.write, step, okc, badc))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:write(('# $%04X-$%04X  exec %d · read %d · write %d\n')
              :format(SCHED_LO, SCHED_HI, hit.exec, hit.read, hit.write))
  out:write(('# 전환 %d · OK %d · 불일치 %d\n'):format(step, okc, badc))
  local pages = {}
  for pg in pairs(acpage) do pages[#pages + 1] = pg end
  table.sort(pages)
  for _, pg in ipairs(pages) do out:write(('# AC $%06X x%d\n'):format(pg, acpage[pg])) end
  out:close()

  say('')
  say(('끝 -- $%04X-$%04X  exec %d · read %d · write %d')
        :format(SCHED_LO, SCHED_HI, hit.exec, hit.read, hit.write))
  if hit.exec == 0 and hit.read == 0 and hit.write == 0 then
    say('   ★ 아무도 안 건드렸다.')
    say('     0.4.7.1 에 올린 것이면 -> 그 자리를 써도 된다는 근거 (여러 장면 필요)')
    say('     0.4.7.2 에 올린 것이면 -> ★스케줄러가 아예 안 돈다.  분기를 볼 것')
  else
    say('   0.4.7.2 라면 정상 (스케줄러가 돈다).  0.4.7.1 이라면 ★그 자리는 못 쓴다')
  end
  say(('   구간 전환 %d 회 · 표와 일치 %d · 불일치 %d'):format(step, okc, badc))
  if badc > 0 then
    say('   ★불일치가 있다 -- TAI 직후 AC 자동증가 가정을 의심할 것')
  elseif okc >= #MINI then
    say(('   ★39 구간 전부 표와 일치 -- TAI 자동증가 가정이 실기로 확인됐다'))
  end
  say('   AC 페이지:')
  for _, pg in ipairs(pages) do
    local mark = (pg == AC_MINI_PAGE) and '   <- ★ mini index 자리' or ''
    say(('     $%06X x%d%s'):format(pg, acpage[pg], mark))
  end
  if acpage[AC_MINI_PAGE] == nil then
    say('     $1FEB00 을 아무도 안 열었다 -- 다른 코드가 안 쓴다는 뜻 (선적재 안전)')
  end
  say('   ' .. PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.166-cdda-scheduled-verify armed -- 순수 관측')
say(('  스케줄러 구간 $%04X-$%04X · mini 표 %d 구간 (프레임 %d..%d)')
      :format(SCHED_LO, SCHED_HI, #MINI, MINI[1].f, MINI[#MINI].f))
say('  트랙 17(오프닝)을 끝까지 틀 것.  승격 판정은 대사·메뉴·장면전환도 필요')
say('  ' .. PATH)
