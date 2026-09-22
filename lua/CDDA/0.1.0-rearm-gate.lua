-- CDDA 0.1.0 -- CD-DA 자막 **무장 관문**을 본다
--
-- ★ 순수 관측.  아무것도 안 쓴다.  화면에도 아무것도 안 그린다.
--
-- 왜
-- --
-- 2026-09-07, 트랙 20 나레이션이 **통째로 두 번 재생된다** (안드로이드·PC
-- 레트로아크 / Beetle PCE SuperGrafx).  메센은 400 FPS 로 오래 돌려도 안 난다.
--
-- Mednafen 디버거 실측 (RC3, 마스터클럭 21.48 MHz):
--
--     t= 0.00   $F9DC  무장   (LDA #$02 -> STA $5E1A)
--     t=25.64   $FF59  철거   (STZ $5E1A)          자막 6줄을 다 썼다
--     t=25.65   $F9DC  재무장 ★0.014 초 뒤.  한 프레임도 안 된다
--     t=51.27   $FF59  철거
--
-- `state==2` 인 동안만 무장 관문이 닫혀 있다 ($F399 의 프레임 분기).  철거가
-- state=0 을 쓰는 순간 관문이 열리는데 **트랙은 아직 재생 중이다** (트랙 20 =
-- 자막 25.5 초 / 음악 29.7 초).  그래서 다음 프레임에 같은 트랙을 다시 문다.
-- 두 번째 묶음의 첫 자막은 12.9 초 뒤라 이미 **다음 장면 위**다.
--
-- 이 프로브가 답할 것 -- 둘
-- -------------------------
--   ① 정상 무장 때 `$20A2`(CD_SUBQ 트랙)와 `$5E1B`(무장된 트랙)가 **다른가**
--
--      막으려는 걸쇠가 이 비교를 쓴다.  새 트랙을 걸 때 이미 같아져 있으면
--      걸쇠가 **정당한 무장까지 막는다** -- rc4·rc5·rc6 이 그렇게 실패했다.
--      메센은 버그가 안 나지만 **정상 무장은 그대로 일어나므로** 여기서 잰다.
--
--   ② 철거 순간 펄스($263C/$2638)가 서 있나
--
--      Beetle 에서만 재무장이 나는 이유가 여기라고 본다.  메센 값을 떠 두면
--      Mednafen 에서 같은 자리를 읽어 **곧바로 대조**할 수 있다.
--
-- 쓰는 법
-- -------
--     메센에서 RC2 (또는 RC3) 를 켜고 이 스크립트를 올린다.
--     ⚠ 상태를 바꾸는 다른 Lua 는 같이 올리지 말 것.
--
--     오프닝(트랙 17)만 지나도 ①은 답이 나온다.
--     트랙 20 장면까지 가면 ②까지 채워진다.
--
-- 산출물  C:/snatcher/dump/cdda_gate_0_1_0_<시각>.tsv
--
-- ===========================================================================

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/cdda_gate_0_1_0_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))

local function say(m) emu.log(m); print(m) end

-- ROM 상주판(0.6.0-rc2 이후)의 CD-DA 사설 상태.
--   $5E1A  state   0=놀고있다 · 1=요청받음 · 2=그리는중 · 3=종료
--   $5E1B  무장된 트랙 (BCD).  cdda_start 가 디렉터리 항목에서 읽어 심는다
local STATE_ADDR = 0x5E1A

local WATCH = {
  { name = 'state',      addr = 0x5E1A },   -- CD-DA 사설 상태
  { name = 'armed_bcd',  addr = 0x5E1B },   -- 무장된 트랙 (BCD)
  { name = 'subq_stat',  addr = 0x20A0 },   -- SUBQ 상태 (02 = 재생 중)
  { name = 'subq_trk',   addr = 0x20A2 },   -- SUBQ 트랙 (BCD)  ★걸쇠의 한쪽
  { name = 'raw_26F9',   addr = 0x26F9 },   -- cdda_check 의 raw 키
  { name = 'pulse_263C', addr = 0x263C },   -- 시작 펄스
  { name = 'pulse_2638', addr = 0x2638 },   -- 시작 펄스
}

local hdr = { 'frame', 'kind', 'pc' }
for _, w in ipairs(WATCH) do hdr[#hdr + 1] = w.name end
hdr[#hdr + 1] = 'note'
out:write(table.concat(hdr, '\t') .. '\n')

local frame = 0
local last = {}
local rows = 0
local arms, teardowns = 0, 0

local function rd(a) return emu.read(a, MEM, false) or -1 end

-- PC 는 Mesen 판마다 모양이 달라 실패해도 관측을 멈추지 않는다.
local function pc()
  local ok, st = pcall(emu.getState)
  if not ok or type(st) ~= 'table' then return -1 end
  local c = st.cpu
  if type(c) ~= 'table' then return -1 end
  return c.pc or c.PC or -1
end

local function snapshot(kind, note)
  local vals = {}
  for _, w in ipairs(WATCH) do vals[#vals + 1] = ('%02X'):format(rd(w.addr)) end
  local p = pc()
  out:write(('%d\t%s\t%s\t%s\t%s\n'):format(
    frame, kind, p >= 0 and ('%04X'):format(p) or '-',
    table.concat(vals, '\t'), note or ''))
  rows = rows + 1
  if rows % 32 == 0 then out:flush() end
end

-- ---- state 가 바뀌는 순간을 전부 잡는다 -----------------------------------
--
-- ★ 무장/철거가 여기서 갈린다.  값과 **그때의 PC** 가 같이 남아야 어느
--   경로로 들어왔는지 안다 (Mednafen 에서 본 $F9DC / $FF59 와 대조).
emu.addMemoryCallback(function(addr, value)
  local before = last['state']
  local kind
  if value == 2 then
    kind = 'ARM'; arms = arms + 1
  elseif value == 0 then
    kind = 'TEARDOWN'; teardowns = teardowns + 1
  else
    kind = 'STATE=' .. tostring(value)
  end
  -- ★ 이 시점의 $20A2 와 $5E1B 가 이 프로브의 목적이다.
  --   무장인데 둘이 **같으면** 걸쇠가 정당한 무장을 막는다는 뜻이다.
  local subq, armed = rd(0x20A2), rd(0x5E1B)
  local verdict = ''
  if kind == 'ARM' then
    verdict = (subq == armed) and 'GATE_WOULD_BLOCK' or 'gate_ok'
  end
  snapshot(kind, ('%s -> %02X  subq=%02X armed=%02X %s')
    :format(before and ('%02X'):format(before) or '?', value, subq, armed, verdict))
  say(('f%-7d %-10s pc=%s  $20A2=%02X $5E1B=%02X  %s')
    :format(frame, kind, ('%04X'):format(pc()), subq, armed, verdict))
end, emu.callbackType.write, STATE_ADDR, STATE_ADDR, CPU, MEM)

-- ---- 그 밖의 바이트가 바뀌면 한 줄 ----------------------------------------
emu.addEventCallback(function()
  frame = frame + 1
  local changed = {}
  for _, w in ipairs(WATCH) do
    local v = rd(w.addr)
    if last[w.name] ~= nil and last[w.name] ~= v then
      changed[#changed + 1] = ('%s %02X->%02X'):format(w.name, last[w.name], v)
    end
    last[w.name] = v
  end
  if #changed > 0 then snapshot('CHANGE', table.concat(changed, ' ')) end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  say('')
  say(('끝  프레임 %d · 무장 %d · 철거 %d · 기록 %d 줄')
    :format(frame, arms, teardowns, rows))
  out:write('#\n')
  out:write(('# frames=%d arms=%d teardowns=%d\n'):format(frame, arms, teardowns))
  out:close()
  say('-> ' .. PATH)
end, emu.eventType.scriptEnded)

say('CDDA 0.1.0 무장 관문 관측 시작')
say('-> ' .. PATH)
say('  ARM 줄의 subq/armed 가 같으면 GATE_WOULD_BLOCK 이 찍힌다')
