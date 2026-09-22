-- SUB 0.5.170 -- CD-DA 스케줄러 검증 (0.4.7.2) · ★가벼운 판
--
-- ★ 순수 관측.  아무것도 안 쓴다.
--
-- 0.5.169 가 왜 게임을 22 FPS 로 만들었나
-- --------------------------------------
-- 0.4.7.1 에서는 $ECF9-$F04D 에 코드가 없어 콜백이 드물었다.  그런데 0.4.7.2 는
-- **스케줄러가 매 프레임 그 안에서 돈다.**  명령마다 콜백이 터지는데 그때마다
-- emu.getState() 를 불렀다 -- 초당 만 번대라 호스트가 못 따라간다.
-- 느려지면 자막 타이밍도 같이 무너져서 "자막이 깨진 것처럼" 보인다.
--
-- 이 판의 원칙
-- ------------
-- 콜백 안에서는 **덧셈만** 한다.  emu.getState() 는 한 번도 안 부른다.
--
-- 뱅크 판별을 getState 없이 하는 법:
--   $FFD4 실행 -> 뱅크1 창이 열렸다 (PHP·SEI·LDA #$01·TAM $80·JMP)
--   $F050 실행 -> 닫혔다            (PLA·PLP·RTS)
-- 이 두 곳에 불 하나만 켜고 끄면, 범위 콜백은 그 불만 보면 된다.
--
-- 보는 것
-- -------
--   1  ★뱅크1 exec -- 스케줄러가 실제로 도는가 (0 이면 안 돈다)
--   2  ★ 렌더러 즉치 3 개 + record_ptr 이 mini index 표와 일치하는가 (39/39)
--   3  AC $1FEB00 페이지를 여는가
--
-- ⚠ 트랙 17(오프닝)을 끝까지 틀 것 (프레임 2189..7233).
--
-- 산출물  C:/snatcher/dump/cdda_light_0_5_170_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/cdda_light_0_5_170_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tkind\tdetail\n')

local function say(m) emu.log(m); print(m) end

local SCHED_LO, SCHED_HI = 0xECF9, 0xF04D
local OPEN_AT, CLOSE_AT = 0xFFD4, 0xF050
local STATE_AT = 0x7FDF
local ENGINE   = 0x5B80
local OFF_HI, OFF_LO, OFF_AT = 200, 235, 240
local OFF_PTR  = 324
local AC_MINI_PAGE = 0x1FEB00

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

local frame  = 0
local win    = false       -- 뱅크1 창이 열려 있나 (불 하나)
local opens  = 0
local b1exec = 0           -- ★창 안에서의 exec = 스케줄러
local b0exec = 0           -- 창 밖 (원본 시스템카드 -- 무관)
local acpage = {}
local last = nil
local step, okc, badc = 0, 0, 0

-- ↓↓ 여기부터 세 콜백은 덧셈만 한다.  getState 없음
emu.addMemoryCallback(function()
  win = true
  opens = opens + 1
end, emu.callbackType.exec, OPEN_AT, OPEN_AT, CPU, MEM)

emu.addMemoryCallback(function()
  win = false
end, emu.callbackType.exec, CLOSE_AT, CLOSE_AT, CPU, MEM)

emu.addMemoryCallback(function()
  if win then b1exec = b1exec + 1 else b0exec = b0exec + 1 end
end, emu.callbackType.exec, SCHED_LO, SCHED_HI, CPU, MEM)
-- ↑↑

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
    if badc <= 8 then
      say(('★불일치 f%-7d 구간 #%d  받음 %s  기대 %02X/%02X/%02X/%06X')
            :format(frame, step, now, want.hi, want.lo, want.at, want.p))
    end
    out:write(('%d\tBAD\t#%d got %s want %02X/%02X/%02X/%06X\n')
                :format(frame, step, now, want.hi, want.lo, want.at, want.p))
  end
  out:flush()
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if frame % 600 == 0 then
    say(('심박 f%-7d ★스케줄러 exec %d · 창열림 %d · 창밖(무관) %d   전환 %d (OK %d · 불일치 %d)')
          :format(frame, b1exec, opens, b0exec, step, okc, badc))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:write(('# 창열림 %d · ★스케줄러 exec %d · 창밖 %d\n')
              :format(opens, b1exec, b0exec))
  out:write(('# 전환 %d · OK %d · 불일치 %d\n'):format(step, okc, badc))
  local pages = {}
  for pg in pairs(acpage) do pages[#pages + 1] = pg end
  table.sort(pages)
  for _, pg in ipairs(pages) do out:write(('# AC $%06X x%d\n'):format(pg, acpage[pg])) end
  out:close()

  say('')
  say(('끝 -- ★스케줄러 exec %d · 창열림 %d · 창밖(무관) %d')
        :format(b1exec, opens, b0exec))
  say(('     구간 전환 %d 회 · 표와 일치 %d · 불일치 %d'):format(step, okc, badc))
  say('')
  if b1exec == 0 then
    say('★ 스케줄러가 아예 안 돈다 -- 디스패처의 CD-DA 분기를 볼 것')
    say('  (매체 지문 $CD @ 렌더러+670)')
  else
    say(('★ 스케줄러가 돈다 -- exec %d 회'):format(b1exec))
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

say('SUB 0.5.170-cdda-verify-light armed -- 순수 관측 · getState 안 부름')
say(('  스케줄러 $%04X-$%04X · 창 $%04X 열고 $%04X 닫음 · mini 표 %d 구간')
      :format(SCHED_LO, SCHED_HI, OPEN_AT, CLOSE_AT, #MINI))
say('  ★0.4.7.2 에 올릴 것.  트랙 17(오프닝)을 끝까지')
say('  ' .. PATH)
