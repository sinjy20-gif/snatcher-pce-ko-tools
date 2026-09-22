-- SUB 0.5.163 -- 지연 arm 이 어디서 멈추는가 (0.4.6.74 진단)
--
-- ★ 순수 관측.  아무것도 안 고친다.
--
-- 증상: 0.4.6.74 에서 앞쪽 6 개쯤 빼고 **모든 자막이 죽는다.**
--
-- 지연 arm 의 길은 셋이다.  어디서 끊기는지 가른다.
--
--     A  슬롯이 A1 이 된다              (음성 감지 자체)
--     B  FEC4 가 pending=1 을 세운다    (arm_new_hit)
--     C  pending 이 0 으로 내려간다     (RCR 줄160 또는 안전밸브)
--     D  STATE 에 1 이 써진다           (arm 이 실제로 끝났다)
--
--     A 는 오는데 B 가 없다  -> arm_idle 에 못 들어간다 (STATE 가 0 이 아니다)
--     B 는 오는데 C 가 없다  -> RCR 도 안전밸브도 안 돈다.  pending 이 갇혔다
--     C 는 오는데 D 가 없다  -> arm_deferred_run 이 돌다 죽거나 검색이 miss
--     D 까지 오는데 자막 없음 -> arm 은 됐고 렌더러/스케줄러 쪽 문제
--
-- 같이 본다
--     seq($1F2718)  순번.  **프레임당 3 씩 올라가기만 하면** 리셋이 안 되는 것이다
--                   (설계는 FEC4 가 매 프레임 0 으로 되돌리는 것)
--     STATE 쓰기의 PC -- 누가 썼는지
--
-- 산출물  C:/snatcher/dump/arm_alive_0_5_163_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local AC = emu.memType.pceArcadeCardRam

local STATE_ADDR = 0x7FDF
local AC_SLOT    = 0x1F2700
local AC_SEQ     = 0x1F2718
local AC_PEND    = 0x1F2719
local ADPCM_CTRL = 0x180D

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/arm_alive_0_5_163_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tkind\tstate\tslot\tseq\tpend\tplay\tpc\tnote\n')

local function say(m) emu.log(m); print(m) end
local function rd(a)  local ok,v = pcall(emu.read, a, MEM); return (ok and type(v)=='number') and v or -1 end
local function rac(a) local ok,v = pcall(emu.read, a, AC);  return (ok and type(v)=='number') and v or -1 end

local PCK = nil
local function pcNow()
  local ok, s = pcall(emu.getState); if not ok or not s then return -1 end
  if PCK == nil then
    PCK = false
    for _, k in ipairs({'cpu.pc','pc'}) do if type(s[k])=='number' then PCK=k break end end
  end
  if PCK == false then return -1 end
  local v = s[PCK]; return type(v)=='number' and math.floor(v) or -1
end

local frame, last = 0, nil
local nA, nB, nC, nD = 0, 0, 0, 0
local seqPrev, seqStuck = -1, 0

emu.addMemoryCallback(function(address, value)
  local v = (value or 0) & 0xFF
  if v == 1 then nD = nD + 1 end
  out:write(('%d\tST=%02X\t%d\t%02X\t%d\t%d\t%d\t%04X\tSTATE 쓰기\n'):format(
    frame, v, v, rac(AC_SLOT), rac(AC_SEQ), rac(AC_PEND),
    ((rd(ADPCM_CTRL) & 0x20) ~= 0) and 1 or 0, pcNow()))
  if v == 1 then
    say(('  D  f%-7d STATE=1 (arm 완료)  pc=$%04X'):format(frame, pcNow()))
  end
end, emu.callbackType.write, STATE_ADDR, STATE_ADDR, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  local state = rd(STATE_ADDR)
  local slot  = rac(AC_SLOT)
  local seq   = rac(AC_SEQ)
  local pend  = rac(AC_PEND)
  local play  = ((rd(ADPCM_CTRL) & 0x20) ~= 0) and 1 or 0

  -- 순번이 계속 오르기만 하는가 (리셋이 안 되는가)
  if seq >= 0 then
    if seqPrev >= 0 and seq ~= 0 and seq > seqPrev then seqStuck = seqStuck + 1
    elseif seq == 0 then seqStuck = 0 end
    seqPrev = seq
  end

  local k = ('%d|%02X|%d|%d'):format(state, slot, pend, play)
  if k == last then return end
  last = k

  local kind = 'SET'
  if slot == 0xA1 then nA = nA + 1; kind = 'A1' end
  if pend == 1 then nB = nB + 1; kind = 'PEND' end
  out:write(('%d\t%s\t%d\t%02X\t%d\t%d\t%d\t\t\n'):format(
    frame, kind, state, slot, seq, pend, play))
  out:flush()
  if slot == 0xA1 or pend ~= 0 then
    say(('  %-4s f%-7d state=%d slot=%02X seq=%-3d pend=%d play=%d')
          :format(kind, frame, state, slot, seq, pend, play))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:write(('# A1 %d · PEND %d · STATE1 %d · seq 연속상승 %d\n'):format(nA, nB, nD, seqStuck))
  out:close()
  say(('끝 -- 슬롯A1 %d · pending 섬 %d · STATE=1 %d · seq 연속상승 %d')
        :format(nA, nB, nD, seqStuck))
  if seqStuck > 60 then
    say('  ★ seq 가 계속 오르기만 한다 -- FEC4 의 순번 리셋이 안 돌고 있다')
  end
end, emu.eventType.scriptEnded)

say('SUB 0.5.163-arm-alive armed -- 순수 관측 (0.4.6.74 진단)')
say('  볼 것: A1 은 오는가 · pending 이 서는가 · 내려가는가 · STATE=1 이 오는가')
say('  ' .. PATH)
