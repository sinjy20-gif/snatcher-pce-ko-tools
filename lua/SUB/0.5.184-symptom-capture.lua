-- SUB 0.5.184 -- 그림 밀림 "증상 순간" 포착기  ★순수 관측 · 쓰기 0 B
--
-- 왜 새로 만드나
-- ---------------------------------------------------------------------------
-- 지금까지 뜬 로그(0.5.24 · 0.5.155 · 0.5.157 · 0.5.159)는 전부 "몇 프레임이
-- 늦었나"를 **세고 끝났다.**  그래서 담긴 것이 죄다 자가복구되는 낱개 지연뿐이다.
--
--     our_span 0.5.159     BYR=96 프레임 21,928 중 늦은 것 32 (0.15%) · 연속 0
--     scroll_base 0.5.157  국장실 본체(n=16)에서 줄32 BYR=96 빠진 프레임 0
--     bat_overlap 0.5.149  빌린 자리와 배경 BAT 겹침 0 (음성 7 개 전부)
--
-- 그런데 소유자는 **밀린 채 유지되는** 그림을 본다.  한 프레임짜리 원인으로
-- 지속 증상을 설명하고 있는 셈이다.  모순이다.
--
-- 논리 상자
--     오버클럭이 고친다  =>  마감 문제다
--     마감 문제다        =>  한 프레임짜리다  (복구 주체가 게임의 '다음 프레임'
--                                             이고 그건 60Hz 에 묶여 있다)
--     관측               =  지속된다
--   셋이 동시에 참일 수 없다.  출구 셋:
--     (1) 실은 지속이 아니라 빠른 반복 깜빡임이다
--     (2) 마감을 놓친 결과가 **걸쇠**로 남는다  ★셋을 다 만족하는 유일한 가설
--     (3) 순서 의존 오염(race)
--
-- 그래서 이 판은 세는 게 아니라 **증상이 난 순간의 앞뒤를 통째로 뜬다.**
--
-- 무엇을 남기나
-- ---------------------------------------------------------------------------
--   매 프레임 링버퍼에 담는다 (앞 600 프레임 = 10 초)
--     CR($05) · RCR($06) · BXR($07) · BYR($08) 쓰기를 스캔라인까지 붙인 서명
--     byr96  = BYR 하위 96 이 쓰인 스캔라인 (없으면 -1)
--     eng    = 우리 자막 엔진이 떠 있나 · state = $7FDF
--     bat    = BAT 표본 해시 (내용이 바뀌었는지)
--   방아쇠가 당겨지면 링 + 뒤 180 프레임을 한 파일로 쏟는다
--
-- 방아쇠 둘
--   E 키 (수동)   ★이게 진짜 근거다.  "지금 밀려 보인다" 를 소유자가 찍는다
--   자동          byr96 이 사라졌거나 줄 33 이후로 늦었다
--
-- 판정 -- 에피소드 파일 한 장이면 셋 중 하나로 확정된다
--   E 표시 근처에서 byr96 이 매 프레임 줄 32 로 정상  ->  레지스터 무죄.
--        그런데 화면이 밀려 있었다면 남은 건 내용(bat) 또는 게임 상태
--   E 표시 뒤로 byr96 이 계속 -1 이거나 계속 늦다     ->  ★걸쇠 확정 (2)
--   E 표시 앞뒤로 낱개 지연만 흩어져 있다             ->  (1) 깜빡임.  현행 진단 맞다
--   bat 해시가 어느 프레임에서 바뀌고 안 돌아온다     ->  ★내용 오염 (3)
--
-- 쓰는 법
--   1) 다른 Lua 전부 끄고 이것만 로드 (세대 혼합 금지 -- 0.5.155 머리말 참조)
--   2) 국장실에서 UI 를 열고 닫으며 자막을 태운다
--   3) **밀린 것이 보이는 동안** E 를 누른다.  한 번이면 된다
--      (사람 반응이 늦어도 앞 600 프레임을 되감아 담으므로 시작점이 남는다)
--   4) 밀린 채 그대로면 3 초쯤 뒤 한 번 더 눌러라 -- 지속 증거가 두 장 된다
--   5) Stop.  에피소드마다 파일이 따로 나온다
--
-- 산출물  C:/snatcher/dump/symptom_0_5_184_<시각>_ep<N>.tsv
--         C:/snatcher/dump/symptom_0_5_184_<시각>_index.tsv

local PRE       = 600     -- 방아쇠 앞으로 담을 프레임 (10 초).  손이 늦어도 덮는다
local POST      = 180     -- 방아쇠 뒤로 담을 프레임
local COOLDOWN  = 60      -- 자동 방아쇠 재발동 금지 구간
local MAXT      = 48      -- 한 프레임 쓰기 상한
local BAT_STEP  = 32      -- BAT 표본 간격 (4096 워드 / 32 = 128 표본)
local BAT_IDLE  = 30      -- 대기 중 BAT 표본 주기 (프레임)

local MEM, VRAM, CPU = emu.memType.pceMemory, emu.memType.pceVideoRam, emu.cpuType.pce
local ENGINE, STATE_ADDR = 0x5B80, 0x7FDF

local STAMP = os.date('%Y%m%d_%H%M%S')
local BASE  = 'C:/snatcher/dump/symptom_0_5_184_' .. STAMP
local index = assert(io.open(BASE .. '_index.tsv', 'w'))
index:write('ep\tkind\tframe\tbyr96\tnote\n')
index:flush()

local function say(m) emu.log(m); print(m) end
local function rd(a)  local ok,v = pcall(emu.read, a, MEM);  return (ok and type(v)=='number') and v or -1 end
local function rb(a)  local ok,v = pcall(emu.read, a, VRAM); return (ok and type(v)=='number') and v or 0 end

local function engineUp()
  return rd(ENGINE) == 0x53 and rd(ENGINE+1) == 0x55 and rd(ENGINE+2) == 0x42
end

-- BAT 를 성기게 훑어 32-bit 해시로 접는다.  내용이 바뀌면 값이 바뀐다
local function batHash()
  local h = 0x811C9DC5
  for w = 0, 4095, BAT_STEP do
    local at = w * 2
    local v = rb(at) | (rb(at + 1) << 8)
    h = ((h ~ v) * 16777619) & 0xFFFFFFFF
  end
  return h
end

local LINE_KEY
local function scanline()
  local ok, s = pcall(emu.getState)
  if not ok or not s then return -1 end
  if LINE_KEY == nil then
    LINE_KEY = false
    for _, k in ipairs({'vdc.scanline', 'scanline', 'vdc.vCounter', 'ppu.scanline'}) do
      if type(s[k]) == 'number' then LINE_KEY = k break end
    end
  end
  if LINE_KEY == false then return -1 end
  local v = s[LINE_KEY]
  return type(v) == 'number' and math.floor(v) or -1
end

local REGN = { [0x05]='CR', [0x06]='RCR', [0x07]='BXR', [0x08]='BYR' }
local selReg, trace, truncated = 0, {}, false

emu.addMemoryCallback(function(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF
  if port == 0 then selReg = value return end
  if port ~= 2 and port ~= 3 then return end
  local name = REGN[selReg]
  if not name then return end
  if #trace >= MAXT then truncated = true return end
  trace[#trace + 1] = {
    line = scanline(), reg = name,
    half = (port == 2) and 'lo' or 'hi', value = value,
  }
end, emu.callbackType.write, 0x0000, 0x0003, CPU, MEM)

-- 링버퍼
local ring, ringHead, ringN = {}, 0, 0
local frame, eps = 0, 0
local lastBat, batAge = -1, 0
local armed, armLeft, armEp, armTrig = false, 0, 0, 0
local lastAuto, prevByr = -10000, -1

local function push(rec)
  ringHead = (ringHead % PRE) + 1
  ring[ringHead] = rec
  if ringN < PRE then ringN = ringN + 1 end
end

local function ringInOrder()
  local out, n = {}, ringN
  for i = 1, n do
    local idx = ((ringHead - n + i - 1) % PRE) + 1
    out[i] = ring[idx]
  end
  return out
end

local epFile = nil

local function line(rec, kind)
  return ('%d\t%s\t%d\t%d\t%d\t%d\t%d\t%s\t%d\t%d\t%08X\t%s\n'):format(
    armEp, kind, rec.frame, rec.frame - armTrig, rec.mark, rec.byr96, rec.n,
    rec.trunc and 'CUT' or '', rec.eng, rec.state, rec.bat, rec.sig)
end

local function openEpisode(kind, trigFrame, byr96)
  eps = eps + 1
  armEp, armTrig = eps, trigFrame
  epFile = assert(io.open(('%s_ep%d.tsv'):format(BASE, eps), 'w'))
  epFile:write('ep\tkind\tframe\trel\tmark\tbyr96\tn\ttrunc\teng\tstate\tbat\tsig\n')
  -- 링의 마지막 칸은 방아쇠 프레임 자신이다.  TRIG 로 따로 쓰므로 여기선 뺀다
  local hist = ringInOrder()
  for i = 1, #hist - 1 do epFile:write(line(hist[i], 'PRE')) end
  epFile:flush()
  index:write(('%d\t%s\t%d\t%d\t%s\n'):format(eps, kind, trigFrame, byr96,
    (kind == 'KEY') and '소유자가 밀림을 보고 눌렀다' or '자동'))
  index:flush()
  say(('★ ep%d 시작 (%s) f%d byr96=%d -- 뒤 %d 프레임 담는 중')
      :format(eps, kind, trigFrame, byr96, POST))
end

local function closeEpisode()
  if epFile then epFile:close(); epFile = nil end
  say(('   ep%d 닫음'):format(armEp))
end

-- E 키
local KEY = nil
for _, n in ipairs({ 'E', 'e', 'KeyE' }) do
  local ok, v = pcall(function() return emu.isKeyPressed(n) end)
  if ok and type(v) == 'boolean' then KEY = n break end
end
local held = false

emu.addEventCallback(function()
  frame = frame + 1

  -- 키는 담는 중에도 계속 본다.  안 그러면 누른 채 에피소드가 끝날 때
  -- 눌림 상태가 낡아서 곧바로 새 에피소드가 열린다
  local down = false
  if KEY then down = (emu.isKeyPressed(KEY) == true) end
  local pressed = down and not held
  held = down

  -- 이 프레임 서명
  local parts, byr96 = {}, -1
  for i, w in ipairs(trace) do
    parts[i] = ('%d:%s%s=%d'):format(w.line, w.reg, w.half, w.value)
    if w.reg == 'BYR' and w.half == 'lo' and w.value == 96 then byr96 = w.line end
  end

  -- BAT 해시: 담는 중이면 매 프레임, 아니면 BAT_IDLE 마다
  batAge = batAge + 1
  if armed or batAge >= BAT_IDLE or lastBat < 0 then
    lastBat = batHash(); batAge = 0
  end

  local rec = {
    frame = frame, byr96 = byr96, n = #trace, trunc = truncated,
    eng = engineUp() and 1 or 0, state = rd(STATE_ADDR), mark = pressed and 1 or 0,
    bat = lastBat, sig = table.concat(parts, ' '),
  }
  push(rec)
  trace, truncated = {}, false

  if armed then
    epFile:write(line(rec, (frame == armTrig) and 'TRIG' or 'POST'))
    epFile:flush()
    armLeft = armLeft - 1
    if armLeft <= 0 then armed = false; closeEpisode() end
    prevByr = byr96
    return
  end

  -- 수동 방아쇠
  if pressed then
    openEpisode('KEY', frame, byr96)
    armed, armLeft = true, POST
    epFile:write(line(rec, 'TRIG'))
    epFile:flush()
    prevByr = byr96
    return
  end

  -- 자동 방아쇠: 있다가 사라졌거나, 줄 33 이후로 늦었다
  local bad = (prevByr >= 0 and byr96 < 0) or (byr96 > 33)
  if bad and (frame - lastAuto) > COOLDOWN then
    lastAuto = frame
    openEpisode('AUTO', frame, byr96)
    armed, armLeft = true, POST
    epFile:write(line(rec, 'TRIG'))
    epFile:flush()
  end
  prevByr = byr96
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if armed then closeEpisode() end
  index:write(('# 에피소드 %d 개 · 프레임 %d\n'):format(eps, frame))
  index:close()
  say(('== 끝 · 에피소드 %d 개 · 프레임 %d =='):format(eps, frame))
end, emu.eventType.scriptEnded)

say('SUB 0.5.184-symptom-capture armed -- 순수 관측 · 쓰기 0 B')
if KEY then
  say(('  ★ 밀린 것이 보이는 **동안** %s 를 누른다 (앞 %d · 뒤 %d 프레임 담는다)')
      :format(KEY, PRE, POST))
  say('  ★ 밀린 채 그대로면 3 초 뒤 한 번 더 눌러라 -- 지속 증거가 두 장 된다')
else
  say('  ⚠ E 키 이름을 인식 못 했다.  자동 방아쇠만 돈다')
end
say('  ' .. BASE .. '_ep<N>.tsv')
