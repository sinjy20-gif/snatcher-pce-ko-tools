-- SUB 0.5.168 -- $ECF9-$F04D 승격 판정 (뱅크1 창 안에서만 센다)
--
-- ★ 순수 관측.  아무것도 안 쓴다.
--
-- 0.5.166 / 0.5.167 이 왜 틀렸나
-- ------------------------------
-- CPU $E000-$FFFF 는 MPR7 로 뱅킹된다.  이 BIOS 의 구조는:
--
--   MPR7 = $00   평소.  원본 시스템카드 코드 (파일 0x0000-0x1FFF)
--   MPR7 = $01   우리 창.  우리가 깎아 쓴 자리 (파일 0x2000-0x3FFF)
--                $FFD4 : PHP · SEI · LDA #$01 · TAM $80 · JMP  로 연다
--                $F050 : PLA · PLP · RTS                       로 닫는다
--
-- 우리 스케줄러는 **뱅크$01 의 $ECF9** 에 있다 (파일 0x2CF9).
-- 그런데 0.5.166 은 MPR7 을 안 보고 CPU 주소만 봐서, 평소(MPR7=$00)에
-- 돌아가는 **원본 시스템카드 코드**를 우리 자리 접촉으로 셌다.
-- exec 19,323 은 전부 그것이었다 -- 우리 자리와 무관하다.
--
-- 0.5.167 은 MPR7 을 재긴 했는데 기준을 $FEC4(케이브)로 잡았다.  그런데
-- 케이브도 **뱅크$00** 이라(파일 0x1EC4) 양쪽 다 $00 이 나와 "같으니 진짜"
-- 라고 잘못 판정했다.
--
-- 그래서 이 판은
-- --------------
-- **MPR7 == $01 일 때의 접촉만** 센다.  그게 진짜 우리 자리다.
-- 덤으로 $FFD4(창 열기)를 세서 이 주행에 창이 실제로 열렸는지도 본다
-- -- 창이 한 번도 안 열렸으면 판정이 공허하기 때문이다.
--
--   창 열림 > 0  이고  뱅크1 접촉 == 0   -> ★승격.  그 자리를 써도 된다
--   뱅크1 접촉 > 0                        -> ★그 자리는 못 쓴다
--   창 열림 == 0                          -> 판정 불가.  더 돌려야 한다
--
-- 산출물  C:/snatcher/dump/bank1_window_0_5_168_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/bank1_window_0_5_168_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tkind\tmpr7\taddr\tbyte\n')

local function say(m) emu.log(m); print(m) end

local LO, HI   = 0xECF9, 0xF04D    -- 승격 판정할 자리
local BODY_HI  = 0xEECB            -- 스케줄러가 실제 쓰는 끝 (467 B)
local OPEN_AT  = 0xFFD4            -- 뱅크1 창 열기 트램폴린
local BANK1    = 0x01

local function mpr7()
  local ok, s = pcall(emu.getState)
  if not ok or not s then return -1 end
  return s['memoryManager.mpr[7]'] or s['cpu.mpr7'] or -1
end

local frame  = 0
local opens  = 0                   -- 창이 열린 횟수
local bybank = {}                  -- 접촉 MPR7 분포 (참고용)
local real   = 0                   -- ★뱅크1 접촉 (이게 판정)
local inbody = 0
local logged = 0

emu.addMemoryCallback(function()
  opens = opens + 1
end, emu.callbackType.exec, OPEN_AT, OPEN_AT, CPU, MEM)

local function onhit(kind)
  return function(addr)
    local m = mpr7()
    bybank[m] = (bybank[m] or 0) + 1
    if m ~= BANK1 then return end          -- ★평소 뱅크는 우리 자리가 아니다
    real = real + 1
    local a = addr or 0
    if a <= BODY_HI then inbody = inbody + 1 end
    if logged < 60 then
      logged = logged + 1
      local b = emu.read(a, MEM, false) or -1
      say(('★뱅크1 접촉 f%-7d %-5s $%04X 바이트 $%02X%s')
            :format(frame, kind, a, b, a <= BODY_HI and '   <- 스케줄러 몸통' or ''))
      out:write(('%d\t%s\t%02X\t%04X\t%02X\n'):format(frame, kind, m, a, b))
      out:flush()
    end
  end
end

emu.addMemoryCallback(onhit('exec'),  emu.callbackType.exec,  LO, HI, CPU, MEM)
emu.addMemoryCallback(onhit('read'),  emu.callbackType.read,  LO, HI, CPU, MEM)
emu.addMemoryCallback(onhit('write'), emu.callbackType.write, LO, HI, CPU, MEM)

local function dist(t)
  local ks = {}
  for k in pairs(t) do ks[#ks + 1] = k end
  table.sort(ks)
  local parts = {}
  for _, k in ipairs(ks) do
    parts[#parts + 1] = ('$%02X x%d'):format(k, t[k])
  end
  return #parts > 0 and table.concat(parts, ' · ') or '(없음)'
end

emu.addEventCallback(function()
  frame = frame + 1
  if frame % 1800 == 0 then
    say(('심박 f%-7d 창열림 %d · ★뱅크1 접촉 %d   (전체 접촉 %s)')
          :format(frame, opens, real, dist(bybank)))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:write(('# 창열림($FFD4) %d\n'):format(opens))
  out:write(('# 접촉 MPR7 분포 %s\n'):format(dist(bybank)))
  out:write(('# ★뱅크1 접촉 %d (몸통 %d)\n'):format(real, inbody))
  out:close()

  say('')
  say(('끝 -- 뱅크1 창 열림 %d 회'):format(opens))
  say(('     $%04X-$%04X 접촉 MPR7 분포  %s'):format(LO, HI, dist(bybank)))
  say(('     ★그중 뱅크$01 (우리 자리) %d 회 · 스케줄러 몸통 %d 회')
        :format(real, inbody))
  say('')
  if opens == 0 then
    say('★ 판정 불가 -- 뱅크1 창이 한 번도 안 열렸다.')
    say('  자막이 뜨는 장면을 지나야 한다.  더 돌릴 것')
  elseif real == 0 then
    say(('★ 승격 -- 뱅크1 창이 %d 회 열리는 동안 우리 자리는 아무도 안 건드렸다.')
          :format(opens))
    say('  $ECF9-$F04D 를 써도 된다.  0.4.7.2 의 자리 선택이 옳다')
    say('  (MPR7=$00 쪽 접촉은 원본 시스템카드 코드다 -- 우리와 무관)')
  else
    say(('★ 그 자리는 못 쓴다 -- 뱅크$01 에서 %d 회 접촉했다 (몸통 %d 회)')
          :format(real, inbody))
    say('  스케줄러를 옮겨야 한다')
  end
  say('   ' .. PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.168-bank1-window-only armed -- 순수 관측')
say(('  판정 자리 $%04X-$%04X (몸통 $%04X) · 뱅크$%02X 일 때만 센다')
      :format(LO, HI, BODY_HI, BANK1))
say('  0.4.7.1 에 올릴 것.  같은 코스(오프닝->대사->UI->대사)면 된다')
say('  ' .. PATH)
