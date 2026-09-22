-- SUB 0.5.185 -- 흔들림을 **비율**로 잰다 · 장면 안 가림  ★순수 관측 · 쓰기 0 B
--
-- 0.5.184 가 왜 0 에피소드였나 -- 내 잘못이다
-- ---------------------------------------------------------------------------
-- 0.5.184 의 자동 방아쇠가 이렇게 박혀 있었다:
--
--     byr96 = BYR 하위 값이 **96** 인 쓰기의 스캔라인
--     bad   = byr96 이 사라졌거나 줄 33 이후로 늦었다
--
-- `96` 은 **국장실 값**이다.  폐공장은 그 값을 아예 안 쓴다.  그래서 탐지기가
-- 눈을 감고 있었다.  5,140 프레임을 돌고 0 에피소드가 나온 건 "이상 없음" 이
-- 아니라 "안 보고 있었음" 이다.
--
-- 소유자 관측이 바뀌었다 -- 이게 설계를 통째로 바꾼다
-- ---------------------------------------------------------------------------
--     "UI 는 폐공장 · 자막은 국장실 · 근데 여기저기 다 흔들린다"
--     "자막+UI 출력에서 흔들리고, 지금은 그냥 대사 나오면서도 흔들린다"
--     ★ "원래는 이 정도는 아니었는데 자막 넣고 난 다음에 심해졌다"
--
-- 마지막 줄이 핵심이다.  **있다/없다가 아니라 정도 차이**다.  그러면
-- 에피소드 한 장을 잡는 것보다 **비율을 두 빌드에서 재서 대조**하는 게 맞다.
--
--     원본 BIOS   이상 프레임 N / 600
--     우리 빌드   이상 프레임 M / 600
--     M >> N 이면 우리가 얹은 부하가 범인.  M ≈ N 이면 우리 무죄
--
-- 무엇을 "이상" 으로 보나 -- 장면을 안 가리는 정의
-- ---------------------------------------------------------------------------
-- 값을 박지 않는다.  최근 300 프레임의 스크롤 쓰기 **수열**을 세어서 제일 흔한
-- 것을 그 장면의 `normal` 로 삼고, 그것과 다른 프레임을 이상으로 센다.
-- 장면이 바뀌면 normal 도 따라 바뀐다.  안정되기 전(=최빈이 절반 미만)에는
-- 세지 않는다 -- 전환 구간을 이상으로 오인하지 않으려는 것이다.
--
-- 산출물
-- ---------------------------------------------------------------------------
--   _rate.tsv   600 프레임마다 한 줄.  ★이게 대조용 본체다
--   _ep<N>.tsv  이상이 났을 때 앞 600 · 뒤 180 프레임 통째로
--   _index.tsv  에피소드 목록 + 그때의 normal 수열
--
-- 쓰는 법 -- 두 번 돌려서 _rate.tsv 를 비교한다
-- ---------------------------------------------------------------------------
--   (가) 우리 빌드
--   (나) 대조군  Mesen_2.2.1_Windows/Firmware/
--                  [BIOS] Super CD-ROM System (Japan) (v3.0).pce.JP_ORIGINAL
--                ★ 우리 빌드로 덮여 있을 수 있으니 그 파일을 명시적으로 고를 것
--   같은 자리(폐공장)에서 같은 시간만큼 · 같은 조작으로 돌린다.
--
-- ⚠ 멈춰 있는 동안엔 Lua 가 **한 줄도 안 돈다.**  프레임 어드밴스로 보는 중이면
--   E 를 **누른 채로 한 칸 진행**해야 찍힌다.  보통은 그냥 정상 속도로 놀면 된다
--   -- 자동 방아쇠가 알아서 잡는다.
--
-- ⚠ Lua 는 에뮬 안쪽 타이밍을 안 바꾼다.  호스트 FPS 만 떨어진다.
--   화면 왼쪽 위 ⏸ 표시가 있으면 그건 일시정지지 게임이 무거워진 게 아니다.

local WIN       = 300     -- normal 을 정하는 창
local STABLE    = 0.50    -- 최빈이 이 비율 넘어야 "안정" 으로 본다
local REPORT    = 600     -- 이만큼마다 _rate.tsv 한 줄
local PRE       = 600     -- 에피소드 앞으로 담을 프레임
local POST      = 180     -- 에피소드 뒤로 담을 프레임
local COOLDOWN  = 300     -- 에피소드 재발동 금지 (비율은 계속 센다)
local MAX_EPS   = 12      -- 파일 폭발 방지
local MAXT      = 48      -- 한 프레임 쓰기 상한
local BAT_STEP  = 32
local BAT_IDLE  = 30

local MEM, VRAM, CPU = emu.memType.pceMemory, emu.memType.pceVideoRam, emu.cpuType.pce
local ENGINE, STATE_ADDR = 0x5B80, 0x7FDF

local STAMP = os.date('%Y%m%d_%H%M%S')
local BASE  = 'C:/snatcher/dump/shake_0_5_185_' .. STAMP

local rate = assert(io.open(BASE .. '_rate.tsv', 'w'))
rate:write('from\tto\tframes\tanom\tanom_pct\teng_frames\tanom_eng\tanom_noeng\tnormal\n')
rate:flush()

local index = assert(io.open(BASE .. '_index.tsv', 'w'))
index:write('ep\tkind\tframe\tnormal\tgot\n')
index:flush()

local function say(m) emu.log(m); print(m) end
local function rd(a) local ok,v = pcall(emu.read, a, MEM);  return (ok and type(v)=='number') and v or -1 end
local function rb(a) local ok,v = pcall(emu.read, a, VRAM); return (ok and type(v)=='number') and v or 0 end

local function engineUp()
  return rd(ENGINE) == 0x53 and rd(ENGINE+1) == 0x55 and rd(ENGINE+2) == 0x42
end

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

-- 최근 WIN 프레임의 수열을 세는 창
local sw, swi, swn, counts = {}, 0, 0, {}

local function pushSig(s)
  swi = (swi % WIN) + 1
  local old = sw[swi]
  if old ~= nil then
    counts[old] = counts[old] - 1
    if counts[old] <= 0 then counts[old] = nil end
  else
    swn = swn + 1
  end
  sw[swi] = s
  counts[s] = (counts[s] or 0) + 1
end

local function normalSig()
  local best, bn = nil, 0
  for s, c in pairs(counts) do if c > bn then best, bn = s, c end end
  return best, bn
end

-- 링버퍼
local ring, ringHead, ringN = {}, 0, 0
local function push(rec)
  ringHead = (ringHead % PRE) + 1
  ring[ringHead] = rec
  if ringN < PRE then ringN = ringN + 1 end
end
local function ringInOrder()
  local out = {}
  for i = 1, ringN do out[i] = ring[((ringHead - ringN + i - 1) % PRE) + 1] end
  return out
end

local frame, eps = 0, 0
local lastBat, batAge = -1, 0
local armed, armLeft, armEp, armTrig = false, 0, 0, 0
local lastEp = -100000
local epFile = nil

-- 구간 집계
local segFrom, segFrames, segAnom = 1, 0, 0
local segEng, segAnomEng, segAnomNo = 0, 0, 0

local function fmt(rec, kind)
  return ('%d\t%s\t%d\t%d\t%d\t%d\t%d\t%s\t%d\t%d\t%08X\t%s\n'):format(
    armEp, kind, rec.frame, rec.frame - armTrig, rec.mark, rec.anom, rec.n,
    rec.trunc and 'CUT' or '', rec.eng, rec.state, rec.bat, rec.sig)
end

local function openEpisode(kind, trigFrame, normal, got)
  eps = eps + 1
  armEp, armTrig = eps, trigFrame
  epFile = assert(io.open(('%s_ep%d.tsv'):format(BASE, eps), 'w'))
  epFile:write('ep\tkind\tframe\trel\tmark\tanom\tn\ttrunc\teng\tstate\tbat\tsig\n')
  local hist = ringInOrder()
  for i = 1, #hist - 1 do epFile:write(fmt(hist[i], 'PRE')) end
  epFile:flush()
  index:write(('%d\t%s\t%d\t%s\t%s\n'):format(eps, kind, trigFrame, normal or '', got or ''))
  index:flush()
  say(('★ ep%d (%s) f%d -- 뒤 %d 프레임 담는 중'):format(eps, kind, trigFrame, POST))
end

local function closeEpisode()
  if epFile then epFile:close(); epFile = nil end
  say(('   ep%d 닫음'):format(armEp))
end

local function flushSeg(upto, normal)
  if segFrames <= 0 then return end
  rate:write(('%d\t%d\t%d\t%d\t%.2f\t%d\t%d\t%d\t%s\n'):format(
    segFrom, upto, segFrames, segAnom, 100.0 * segAnom / segFrames,
    segEng, segAnomEng, segAnomNo, normal or ''))
  rate:flush()
  say(('  %d~%d  이상 %d/%d (%.2f%%)  엔진돈프레임 %d  이상중 엔진 %d / 무엔진 %d')
      :format(segFrom, upto, segAnom, segFrames, 100.0 * segAnom / segFrames,
              segEng, segAnomEng, segAnomNo))
  segFrom, segFrames, segAnom = upto + 1, 0, 0
  segEng, segAnomEng, segAnomNo = 0, 0, 0
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

  local down = false
  if KEY then down = (emu.isKeyPressed(KEY) == true) end
  local pressed = down and not held
  held = down

  local parts = {}
  for i, w in ipairs(trace) do
    parts[i] = ('%d:%s%s=%d'):format(w.line, w.reg, w.half, w.value)
  end
  local sig = table.concat(parts, ' ')

  -- 이 프레임을 넣기 **전** 창으로 normal 을 정한다
  local normal, bn = normalSig()
  local stable = (swn >= WIN) and (bn >= WIN * STABLE)
  local anom = (stable and sig ~= normal) and 1 or 0
  pushSig(sig)

  batAge = batAge + 1
  if armed or batAge >= BAT_IDLE or lastBat < 0 then lastBat = batHash(); batAge = 0 end

  local eng = engineUp() and 1 or 0
  local rec = {
    frame = frame, n = #trace, trunc = truncated, anom = anom,
    eng = eng, state = rd(STATE_ADDR), mark = pressed and 1 or 0,
    bat = lastBat, sig = sig,
  }
  push(rec)
  trace, truncated = {}, false

  -- 집계
  segFrames = segFrames + 1
  if eng == 1 then segEng = segEng + 1 end
  if anom == 1 then
    segAnom = segAnom + 1
    if eng == 1 then segAnomEng = segAnomEng + 1 else segAnomNo = segAnomNo + 1 end
  end
  if segFrames >= REPORT then flushSeg(frame, normal) end

  if armed then
    epFile:write(fmt(rec, 'POST'))
    epFile:flush()
    armLeft = armLeft - 1
    if armLeft <= 0 then armed = false; closeEpisode() end
    return
  end

  local want = pressed or (anom == 1 and (frame - lastEp) > COOLDOWN)
  if want and eps < MAX_EPS then
    lastEp = frame
    openEpisode(pressed and 'KEY' or 'AUTO', frame, normal, sig)
    armed, armLeft = true, POST
    epFile:write(fmt(rec, 'TRIG'))
    epFile:flush()
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if armed then closeEpisode() end
  local normal = normalSig()
  flushSeg(frame, normal)
  rate:write(('# 프레임 %d · 에피소드 %d\n'):format(frame, eps))
  rate:close(); index:close()
  say(('== 끝 · 프레임 %d · 에피소드 %d =='):format(frame, eps))
end, emu.eventType.scriptEnded)

say('SUB 0.5.185-shake-rate armed -- 장면 안 가림 · 쓰기 0 B')
say('  ★ 그냥 정상 속도로 논다.  자동으로 센다')
say(('  %d 프레임마다 이상 비율을 찍는다 -> %s_rate.tsv'):format(REPORT, BASE))
if KEY then
  say(('  %s = 지금 보인다 표시 (멈춰 있으면 누른 채로 한 칸 진행할 것)'):format(KEY))
else
  say('  ⚠ E 키 이름을 인식 못 했다.  자동 방아쇠만 돈다')
end
