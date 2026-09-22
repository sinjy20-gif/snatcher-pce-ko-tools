-- SUB 0.5.167 -- 0.5.166 의 "$ECF9 접촉" 이 진짜인지 가린다
--
-- ★ 순수 관측.  아무것도 안 쓴다.
--
-- 왜 필요한가
-- -----------
-- PCE 는 CPU $E000-$FFFF 가 MPR7 로 뱅킹된다.  emu.memType.pceMemory 는
-- **지금 매핑된 것**을 보는 CPU 주소 뷰다.  그래서 그 순간 MPR7 이 BIOS
-- 뱅크 $01 이 아니면, 남의 뱅크 코드가 우리 자리를 밟은 것처럼 세어진다.
--
--   0.4.7.1 의 $ECF9-$F04D 는 이미지에서 853/853 이 $FF 다.
--   그런데 0.5.166 은 exec 19,323 · read 6,235 를 셌다.
--   $FF 를 1.9 만 번 실행하고도 게임이 멀쩡할 리 없다 -> 딴 뱅크가 의심된다.
--
-- 어떻게 가리나
-- -------------
-- 살아 있다고 아는 뱅크1 코드($FEC4 케이브)에서 MPR7 을 재서 **기준**으로 삼고,
-- $ECF9-$F04D 접촉 때의 MPR7 과 비교한다.
--
--   같다   -> 진짜 우리 자리를 밟았다.  ★그 자리는 못 쓴다 (승격 실패)
--   다르다 -> 딴 뱅크였다.  0.5.166 의 수치는 허수이고 자리는 여전히 유효
--
-- 곁들여 PC 자리의 실제 바이트도 읽는다.  $FF 면 우리가 아는 빈 구간,
-- $FF 가 아니면 그 순간 딴 뱅크가 매핑돼 있었다는 직접 증거다.
--
-- 산출물  C:/snatcher/dump/bank_truth_0_5_167_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/bank_truth_0_5_167_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tkind\tmpr7\taddr\tbyte\n')

local function say(m) emu.log(m); print(m) end

local LO, HI  = 0xECF9, 0xF04D     -- 검증할 자리
local BODY_HI = 0xEECB             -- 스케줄러가 실제로 쓰는 끝 (467 B)
local REF_AT  = 0xFEC4             -- 살아 있다고 아는 뱅크1 코드 (케이브)

local function mpr7()
  local ok, s = pcall(emu.getState)
  if not ok or not s then return -1 end
  return s['memoryManager.mpr[7]'] or s['cpu.mpr7'] or -1
end

local frame   = 0
local ref     = {}                 -- 기준 MPR7 분포
local hit     = {}                 -- 접촉 때 MPR7 분포
local bytes   = {}                 -- 접촉 때 PC 자리 바이트 분포
local nref, nhit, nbody = 0, 0, 0
local logged  = 0

emu.addMemoryCallback(function(addr)
  nref = nref + 1
  if nref > 200000 then return end
  local m = mpr7()
  ref[m] = (ref[m] or 0) + 1
end, emu.callbackType.exec, REF_AT, REF_AT, CPU, MEM)

emu.addMemoryCallback(function(addr)
  nhit = nhit + 1
  local m = mpr7()
  hit[m] = (hit[m] or 0) + 1
  local b = emu.read(addr or 0, MEM, false) or -1
  bytes[b] = (bytes[b] or 0) + 1
  if (addr or 0) <= BODY_HI then nbody = nbody + 1 end
  if logged < 40 then
    logged = logged + 1
    say(('접촉 f%-7d MPR7 $%02X  $%04X  바이트 $%02X%s')
          :format(frame, m, addr or 0, b,
                  (addr or 0) <= BODY_HI and '   <- ★스케줄러 몸통' or ''))
    out:write(('%d\thit\t%02X\t%04X\t%02X\n'):format(frame, m, addr or 0, b))
    out:flush()
  end
end, emu.callbackType.exec, LO, HI, CPU, MEM)

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
    say(('심박 f%-7d 기준($FEC4) %d 회 %s   접촉 %d 회 %s')
          :format(frame, nref, dist(ref), nhit, dist(hit)))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:write(('# 기준 $FEC4 exec %d  MPR7 %s\n'):format(nref, dist(ref)))
  out:write(('# 접촉 $%04X-$%04X exec %d  MPR7 %s\n'):format(LO, HI, nhit, dist(hit)))
  out:write(('# 접촉 바이트 %s\n'):format(dist(bytes)))
  out:write(('# 그중 스케줄러 몸통($%04X 이하) %d 회\n'):format(BODY_HI, nbody))
  out:close()

  say('')
  say(('끝 -- 기준 $FEC4 exec %d 회  MPR7 %s'):format(nref, dist(ref)))
  say(('     접촉 $%04X-$%04X exec %d 회  MPR7 %s'):format(LO, HI, nhit, dist(hit)))
  say(('     접촉 자리 바이트 %s'):format(dist(bytes)))
  say(('     그중 스케줄러 몸통($ECF9-$%04X) %d 회'):format(BODY_HI, nbody))
  say('')

  if nref == 0 then
    say('★ 기준이 안 잡혔다 -- $FEC4 를 한 번도 안 지났다.')
    say('  판정 불가.  대사/자막이 나오는 장면을 지나야 한다')
  elseif nhit == 0 then
    say('★ 접촉 0 -- 그 자리는 아무도 안 건드린다.  써도 된다')
  else
    local same = false
    for m in pairs(hit) do if ref[m] then same = true end end
    if same then
      say('★ 접촉 때 MPR7 이 기준과 같다 -- 진짜 우리 자리다.')
      say('  그 자리는 못 쓴다.  스케줄러를 옮겨야 한다')
    else
      say('★ 접촉 때 MPR7 이 기준과 다르다 -- 딴 뱅크가 매핑돼 있었다.')
      say('  0.5.166 의 exec/read 수치는 허수다.  자리는 여전히 유효하다')
    end
    if bytes[0xFF] and bytes[0xFF] == nhit then
      say('  (자리 바이트가 전부 $FF -- 이미지와 일치)')
    elseif bytes[0xFF] == nil then
      say('  (자리 바이트에 $FF 가 하나도 없다 -- ★딴 뱅크라는 직접 증거)')
    end
  end
  say('   ' .. PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.167-bank-truth armed -- 순수 관측')
say(('  검증 자리 $%04X-$%04X (몸통 $%04X 까지) · 기준 $%04X')
      :format(LO, HI, BODY_HI, REF_AT))
say('  0.4.7.1 에 올릴 것.  0.5.166 과 같은 코스(오프닝->대사->UI->대사)면 된다')
say('  ' .. PATH)
