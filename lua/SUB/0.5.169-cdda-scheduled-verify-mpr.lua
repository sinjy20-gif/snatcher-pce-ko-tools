-- SUB 0.5.169 -- CD-DA 스케줄러 연동 검증 (0.4.7.2) · 뱅크 가림판
--
-- ★ 순수 관측.  아무것도 안 쓴다.
--
-- 0.5.166 과 무엇이 다른가
-- ------------------------
-- 0.5.166 은 $ECF9 접촉을 MPR7 과 무관하게 셌다.  그런데 CPU $E000-$FFFF 는
-- 뱅크가 둘이다:
--
--   MPR7 = $00   평소.  원본 시스템카드      (파일 0x0000-0x1FFF)
--   MPR7 = $01   우리 창.  스케줄러가 여기   (파일 0x2000-0x3FFF)
--                $FFD4 : PHP·SEI·LDA #$01·TAM $80·JMP  로 연다
--
-- 2026-09-04 실측으로 평소 뱅크 쪽 접촉만 25,304 회가 잡혔다.  그래서
-- 0.5.166 의 "exec 0 이면 스케줄러가 안 돈다" 는 **영원히 성립하지 않는다**
-- -- 스케줄러가 죽어 있어도 원본 코드 때문에 exec 가 커진다.
--
-- 이 판은 **MPR7 == $01 일 때만** 센다.  그래야 스케줄러가 진짜 도는지 보인다.
--
-- 보는 것
-- -------
--   1  ★뱅크1 exec -- 스케줄러가 실제로 도는가 (0 이면 안 돈다)
--   2  ★ 렌더러 즉치 3 개 + record_ptr 이 mini index 표와 일치하는가
--      -> TAI 직후 AC 자동증가 가정의 직접 검증.  39/39 여야 한다
--   3  AC $1FEB00 페이지를 여는가 (mini index 선적재 자리)
--
-- ⚠ 트랙 17(오프닝)을 **끝까지** 틀어야 39 구간이 다 지나간다 (프레임 2189..7233).
--
-- 산출물  C:/snatcher/dump/cdda_sched_mpr_0_5_169_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/cdda_sched_mpr_0_5_169_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tkind\tdetail\n')

local function say(m) emu.log(m); print(m) end

local SCHED_LO, SCHED_HI = 0xECF9, 0xF04D
local OPEN_AT  = 0xFFD4
local BANK1    = 0x01
local STATE_AT = 0x7FDF
local ENGINE   = 0x5B80
local OFF_HI, OFF_LO, OFF_AT = 200, 235, 240
local OFF_PTR  = 324
local AC_MINI_PAGE = 0x1FEB00

local function mpr7()
  local ok, s = pcall(emu.getState)
  if not ok or not s then return -1 end
  return s['memoryManager.mpr[7]'] or s['cpu.mpr7'] or -1
end

-- mini index 표 (build/cutscene_subs/cdda_track17_mini_index.bin 과 39/39 대조 완료)
local MINI = {
  {f=2189,hi=0x20,lo=0x00,at=0x9F,p=0x16EB7B},
  {f=2434,hi=0x20,lo=0x00,at=0x9F,p=0x16EBB1},
  {f=2660,hi=0x20,lo=0x00,at=0x9F,p=0x16EBDE},
  {f=2716,hi=0x27,lo=0x38,at=0x9F,p=0x16EBED},
  {f=2927,hi=0x27,lo=0x38,at=0x9F,p=0x16EC1D},
  {f=2958,hi=0x27,lo=0x38,at=0x9F,p=0x16EC29},
  {f=3126,hi=0x27,lo=0x38,at=0x9F,p=0x16EC56},
  {f=3243,hi=0x63,lo=0x18,at=0xBF,p=0x16EC8C},
  {f=3331,hi=0x63,lo=0x18,at=0xBF,p=0x16ECC2},
  {f=3497,hi=0x63,lo=0x18,at=0xBF,p=0x16ECF2},
  {f=3662,hi=0x20,lo=0x00,at=0x9F,p=0x16ED1F},
  {f=3842,hi=0x20,lo=0x00,at=0x9F,p=0x16ED4F},
  {f=3926,hi=0x20,lo=0x00,at=0x9F,p=0x16ED6D},
  {f=4010,hi=0x20,lo=0x00,at=0x9F,p=0x16ED8B},
  {f=4177,hi=0x20,lo=0x00,at=0x9F,p=0x16EDBE},
  {f=4374,hi=0x20,lo=0x00,at=0x9F,p=0x16EDF4},
  {f=4570,hi=0x20,lo=0x00,at=0x9F,p=0x16EE24},
  {f=4722,hi=0x20,lo=0x00,at=0x9F,p=0x16EE51},
  {f=4769,hi=0x20,lo=0x00,at=0x9F,p=0x16EE63},
  {f=4992,hi=0x20,lo=0x00,at=0x9F,p=0x16EE93},
  {f=5040,hi=0x20,lo=0x00,at=0x9F,p=0x16EEA2},
  {f=5142,hi=0x28,lo=0x40,at=0x9F,p=0x16EEB4},
  {f=5323,hi=0x31,lo=0x88,at=0x9F,p=0x16EEEA},
  {f=5521,hi=0x31,lo=0x88,at=0x9F,p=0x16EF17},
  {f=5566,hi=0x31,lo=0x88,at=0x9F,p=0x16EF26},
  {f=5811,hi=0x72,lo=0x90,at=0xBF,p=0x16EF56},
  {f=5897,hi=0x72,lo=0x90,at=0xBF,p=0x16EF7A},
  {f=5957,hi=0x72,lo=0x90,at=0xBF,p=0x16EF95},
  {f=6047,hi=0x72,lo=0x90,at=0xBF,p=0x16EFB9},
  {f=6102,hi=0x72,lo=0x90,at=0xBF,p=0x16EFD1},
  {f=6248,hi=0x27,lo=0x38,at=0x9F,p=0x16EFF2},
  {f=6389,hi=0x27,lo=0x38,at=0x9F,p=0x16F022},
  {f=6419,hi=0x27,lo=0x38,at=0x9F,p=0x16F031},
  {f=6590,hi=0x2B,lo=0x58,at=0x9F,p=0x16F05B},
  {f=6730,hi=0x2B,lo=0x58,at=0x9F,p=0x16F082},
  {f=6844,hi=0x2B,lo=0x58,at=0x9F,p=0x16F0A3},
  {f=6942,hi=0x2B,lo=0x58,at=0x9F,p=0x16F0C1},
  {f=7042,hi=0x58,lo=0xC0,at=0xAF,p=0x16F0E2},
  {f=7233,hi=0x58,lo=0xC0,at=0xAF,p=0x16F118},
}

local frame = 0
local opens = 0
local b1    = { exec = 0, read = 0, write = 0 }   -- ★뱅크1 만
local b0    = 0                                   -- 평소 뱅크 (참고)
local acpage = {}
local last = nil
local step, okc, badc = 0, 0, 0

emu.addMemoryCallback(function()
  opens = opens + 1
end, emu.callbackType.exec, OPEN_AT, OPEN_AT, CPU, MEM)

local function watch(kind)
  return function(addr)
    if mpr7() ~= BANK1 then
      b0 = b0 + 1
      return
    end
    b1[kind] = b1[kind] + 1
  end
end

emu.addMemoryCallback(watch('read'),  emu.callbackType.read,  SCHED_LO, SCHED_HI, CPU, MEM)
emu.addMemoryCallback(watch('write'), emu.callbackType.write, SCHED_LO, SCHED_HI, CPU, MEM)
emu.addMemoryCallback(watch('exec'),  emu.callbackType.exec,  SCHED_LO, SCHED_HI, CPU, MEM)

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
    out:write(('%d\tOVER\t%s\n'):format(frame, now))
  elseif hi == want.hi and lo == want.lo and at == want.at and ptr == want.p then
    okc = okc + 1
    out:write(('%d\tOK\t#%d %s\n'):format(frame, step, now))
    if okc <= 5 or step == #MINI then
      say(('OK    f%-7d 구간 #%d  %s'):format(frame, step, now))
    end
  else
    badc = badc + 1
    say(('★불일치 f%-7d 구간 #%d'):format(frame, step))
    say(('        받음 %s'):format(now))
    say(('        기대 %02X/%02X/%02X/%06X'):format(want.hi, want.lo, want.at, want.p))
    out:write(('%d\tBAD\t#%d got %s want %02X/%02X/%02X/%06X\n')
                :format(frame, step, now, want.hi, want.lo, want.at, want.p))
  end
  out:flush()
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if frame % 600 == 0 then
    say(('심박 f%-7d 창열림 %d · ★뱅크1 exec %d (read %d) · 평소뱅크 %d   전환 %d (OK %d · 불일치 %d)')
          :format(frame, opens, b1.exec, b1.read, b0, step, okc, badc))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:write(('# 창열림 %d\n'):format(opens))
  out:write(('# ★뱅크1 $%04X-$%04X exec %d · read %d · write %d\n')
              :format(SCHED_LO, SCHED_HI, b1.exec, b1.read, b1.write))
  out:write(('# 평소뱅크(무관) %d\n'):format(b0))
  out:write(('# 전환 %d · OK %d · 불일치 %d\n'):format(step, okc, badc))
  local pages = {}
  for pg in pairs(acpage) do pages[#pages + 1] = pg end
  table.sort(pages)
  for _, pg in ipairs(pages) do out:write(('# AC $%06X x%d\n'):format(pg, acpage[pg])) end
  out:close()

  say('')
  say(('끝 -- 창열림 %d 회'):format(opens))
  say(('     ★뱅크1 $%04X-$%04X  exec %d · read %d · write %d')
        :format(SCHED_LO, SCHED_HI, b1.exec, b1.read, b1.write))
  say(('     평소뱅크 접촉 %d 회 (원본 시스템카드 -- 무관)'):format(b0))
  say(('     구간 전환 %d 회 · 표와 일치 %d · 불일치 %d'):format(step, okc, badc))
  say('')
  if b1.exec == 0 then
    say('★ 스케줄러가 아예 안 돈다 -- 뱅크1 exec 가 0 이다.')
    say('  디스패처의 CD-DA 분기를 볼 것 (매체 지문 $CD @ 렌더러+670)')
  else
    say(('★ 스케줄러가 돈다 -- 뱅크1 exec %d 회'):format(b1.exec))
  end
  if badc > 0 then
    say('★ 표 불일치가 있다 -- TAI 직후 AC 자동증가 가정을 의심할 것')
  elseif okc >= #MINI then
    say('★ 39 구간 전부 표와 일치 -- TAI 자동증가 가정이 실기로 확인됐다')
  elseif okc > 0 then
    say(('   일치 %d/%d -- 오프닝을 끝까지 안 틀었다'):format(okc, #MINI))
  end
  say('   AC 페이지:')
  for _, pg in ipairs(pages) do
    local mark = (pg == AC_MINI_PAGE) and '   <- ★ mini index 자리' or ''
    say(('     $%06X x%d%s'):format(pg, acpage[pg], mark))
  end
  say('   ' .. PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.169-cdda-scheduled-verify-mpr armed -- 순수 관측')
say(('  스케줄러 $%04X-$%04X (뱅크$%02X 일 때만) · mini 표 %d 구간 (프레임 %d..%d)')
      :format(SCHED_LO, SCHED_HI, BANK1, #MINI, MINI[1].f, MINI[#MINI].f))
say('  ★0.4.7.2 에 올릴 것.  트랙 17(오프닝)을 끝까지 틀 것')
say('  ' .. PATH)
