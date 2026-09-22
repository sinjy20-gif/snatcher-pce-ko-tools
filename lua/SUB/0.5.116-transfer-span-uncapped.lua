-- SUB 0.5.116 -- 0.5.115 가 잘라먹은 큰 버스트의 진짜 스팬을 잰다 (쓰기 0 B)
--
-- 0.5.115 가 뭘 놓쳤나
-- ---------------------------------------------------------------------------
-- 0.5.115 는 `SAMPLE_EVERY=8` · `SAMPLE_CAP=256` 이었다.  그래서 표본 추출이
-- **히트 2040 번째에서 멈춘다.**  그보다 큰 버스트는 `exec_last` 가 마지막 줄이
-- 아니라 2040 번째 히트의 줄이다.
--
--     f709   hits 13815   45->63   span 18      <- 거짓.  잘린 값이다
--     f898   hits 13758   43->61   span 18      <- 거짓
--
-- 13,815 명령은 18 스캔라인(약 8,170 사이클)에 못 들어간다.  산술로도 불가능하다.
-- 그런데 하필 이 둘이 **종료 복원**의 유력 후보다 (state=0 · 덩치 10 배).
--
-- 0.5.115 로 확정된 것 (다시 안 잰다)
-- ---------------------------------------------------------------------------
--     전송이 VBlank 에 들어간 적이 없다.  전부 활성 표시 구간이다
--     hits<2040 인 여섯 버스트는 스팬이 온전하다 -- 3..97 줄 사이
--     정상 프레임은 hits=27 · span 0~1 · line 23~33 (상주 폴링.  무해)
--
-- 이 판이 새로 묻는 것
-- ---------------------------------------------------------------------------
--     1. 큰 버스트(13,000+ 히트)의 진짜 스팬은 얼마인가
--     2. 그 창이 **자막 자신의 래스터 줄**을 가로지르는가
--
-- (2)가 핵심이다.  자막은 y=122(`중간`)에 그려진다.  전송이 line 97 에 끝나면
-- 래스터가 122 에 올 때 이미 업로드가 끝나 있어 그 프레임은 깨끗하다.
-- 찢어지려면 전송 창이 122 를 **가로질러야** 한다.  0.5.115 에서 그런 건
-- `f510  83->164` 하나뿐이었다 -- 그래서 매번이 아니라 "찰나" 인 것이다.
--
-- 무엇을 바꿨나
-- ---------------------------------------------------------------------------
--     상한 제거          큰 버스트도 끝까지 따라간다
--     적응 표본          작을 땐 촘촘히, 커지면 성기게 -- 비용은 그대로 묶인다
--                          히트 <=512   : 8 마다
--                          히트 <=4096  : 64 마다
--                          그 위        : 256 마다
--                        13,815 히트여도 getState 는 약 180 회다
--     min/max 기록       wrap 이 있어도 창의 실제 폭을 잃지 않는다
--     crosses 판정       창이 자막 띠(BAND_LO..BAND_HI)를 가로지르는가
--
-- ★ BAND 는 가정이 섞인 값이다.  y=122 가 글리프 윗줄이라 보고 16 px 높이를
--   더한 뒤 여유를 뒀다.  min/max 를 같이 찍으므로, 띠가 틀렸어도 원자료로
--   다시 판정할 수 있다.  band 만 보고 닫지 말 것.
--
-- 읽는 법
-- ---------------------------------------------------------------------------
--     큰 버스트의 span 이 100+ 로 나온다      -> 화면 절반을 먹는다.  (나) 강화
--     crosses=YES 인 프레임이 있다            -> ★ 그 프레임이 찢어진 프레임이다
--     crosses=YES 가 하나도 없다              -> 찢김의 방아쇠는 다른 데 있다
--                                                (이 판으로는 못 잡는다.  닫지 말 것)
--
--     ⚠ exec_hits > 0 인데 vdc_writes = 0 이면 TIA 쓰기를 콜백이 못 본 것이다.
--       "전송 없음" 이 아니다.  vdc_* 를 버리고 exec_* 만 읽는다.
--
-- ★ 화면에 아무것도 안 그린다.  게임을 한 바이트도 안 고친다.
--
--   BIOS  build/patch/0.4.6.68/Syscard3_galmuri_0.4.6.68.pce
--   CUE   build/patch/0.4.6.68/Snatcher CD-ROMantic (Japan) [KO].cue
--   Power Cycle -> 이 파일만 로드 -> 0.5.115 와 **같은 장면**을 같은 순서로
--                  (f709/f898 에 해당하는 큰 버스트를 다시 만나야 한다)
--
-- 산출물  C:/snatcher/dump/transfer_span_0_5_116_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local ENGINE_LO, ENGINE_HI = 0x5B80, 0x5E1F
local VDC_LO,    VDC_HI    = 0x0000, 0x0003

local STATE_ADDR  = 0x7FDF
local CTL_STATUS  = 0x5D31
local CTL_CMD     = 0x5D30

local LINES        = 263
local DISPLAY_LAST = 238

-- 자막 띠 -- y=122(`중간`) + 글리프 높이 16 px + 여유.  ★가정값
local BAND_LO, BAND_HI = 118, 145

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/transfer_span_0_5_116_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tstate\tstatus\tcmd\tadpcm\t'
       .. 'exec_hits\texec_first\texec_last\texec_min\texec_max\texec_span\t'
       .. 'exec_where\tcrosses\tsamples\t'
       .. 'vdc_writes\tvdc_first\tvdc_last\tvdc_span\n')

local function say(f, ...) emu.log(string.format(f, ...)) end
local function rd(a)
  local ok, v = pcall(emu.read, a, MEM)
  return (ok and type(v) == 'number') and v or -1
end

local LINE_KEY
local function scanline()
  local ok, s = pcall(emu.getState)
  if not ok or not s then return -1 end
  if LINE_KEY == nil then
    LINE_KEY = false
    for _, k in ipairs({ 'vdc.scanline', 'scanline', 'vdc.vCounter', 'ppu.scanline' }) do
      if type(s[k]) == 'number' then LINE_KEY = k; break end
    end
    if LINE_KEY == false then
      say('0.5.116 ⚠ 스캔라인 키를 못 찾았다 -- 아무 판정도 하지 말 것')
    else
      say('0.5.116 스캔라인 키 = %s', LINE_KEY)
    end
  end
  if LINE_KEY == false then return -1 end
  local v = s[LINE_KEY]
  return type(v) == 'number' and math.floor(v) or -1
end

local function adpcmOn()
  local ok, s = pcall(emu.getState)
  if not ok or not s then return '?' end
  local v = s['cdrom.adpcm.playing']
  if v == nil then v = s['cdrom.adpcm.isPlaying'] end
  if type(v) == 'boolean' then return v and '1' or '0' end
  if type(v) == 'number' then return v ~= 0 and '1' or '0' end
  return '?'
end

local function isDisplay(l) return l >= 0 and l <= DISPLAY_LAST end

local function where(first, last)
  if first < 0 or last < 0 then return '-' end
  local a, b = isDisplay(first), isDisplay(last)
  if a and b then return '표시' end
  if not a and not b then return 'VBlank' end
  return '걸침'
end

local function spanOf(first, last)
  if first < 0 or last < 0 then return -1 end
  return (last - first + LINES) % LINES
end

-- 적응 간격 -- 버스트가 커질수록 성기게 뜬다.  getState 비용을 묶어둔다
local function everyFor(hits)
  if hits <= 512  then return 8   end
  if hits <= 4096 then return 64  end
  return 256
end

local frame = 0
local eHits, eFirst, eLast, eMin, eMax, eSamp = 0, -1, -1, -1, -1, 0
local vHits, vFirst, vLast, vSamp = 0, -1, -1, 0
local rows, tiaBlind, execFrames, crossFrames = 0, 0, 0, 0

local function resetFrame()
  eHits, eFirst, eLast, eMin, eMax, eSamp = 0, -1, -1, -1, -1, 0
  vHits, vFirst, vLast, vSamp = 0, -1, -1, 0
end

emu.addMemoryCallback(function()
  eHits = eHits + 1
  if eHits == 1 or eHits % everyFor(eHits) == 0 then
    local l = scanline()
    eSamp = eSamp + 1
    if l >= 0 then
      if eFirst < 0 then eFirst = l end
      eLast = l
      if eMin < 0 or l < eMin then eMin = l end
      if eMax < 0 or l > eMax then eMax = l end
    end
  end
end, emu.callbackType.exec, ENGINE_LO, ENGINE_HI, CPU, MEM)

emu.addMemoryCallback(function()
  vHits = vHits + 1
  if vHits == 1 or vHits % everyFor(vHits) == 0 then
    local l = scanline()
    vSamp = vSamp + 1
    if l >= 0 then
      if vFirst < 0 then vFirst = l end
      vLast = l
    end
  end
end, emu.callbackType.write, VDC_LO, VDC_HI, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  if eHits > 0 then
    execFrames = execFrames + 1
    if vHits == 0 then tiaBlind = tiaBlind + 1 end

    -- 창이 자막 띠를 가로지르는가 (min..max 로 본다.  wrap 은 별도 표시)
    local crosses = '-'
    if eMin >= 0 and eMax >= 0 then
      crosses = (eMin <= BAND_HI and eMax >= BAND_LO) and 'YES' or 'no'
    end
    if crosses == 'YES' then crossFrames = crossFrames + 1 end

    local eW = where(eFirst, eLast)
    out:write(string.format(
      '%d\t%d\t%d\t%d\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%s\t%d\t%d\t%d\t%d\t%d\n',
      frame, rd(STATE_ADDR), rd(CTL_STATUS), rd(CTL_CMD), adpcmOn(),
      eHits, eFirst, eLast, eMin, eMax, spanOf(eFirst, eLast), eW, crosses, eSamp,
      vHits, vFirst, vLast, spanOf(vFirst, vLast)))
    out:flush()
    rows = rows + 1

    if eHits >= 400 or crosses == 'YES' then
      say('0.5.116 f%d state=%d hits=%d  %d->%d (min %d max %d) span=%d %s  자막띠교차=%s  표본=%d',
          frame, rd(STATE_ADDR), eHits, eFirst, eLast, eMin, eMax,
          spanOf(eFirst, eLast), eW, crosses, eSamp)
    end
  end
  resetFrame()
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:close()
  say('0.5.116 끝 -- 우리 코드가 돈 프레임 %d · 기록 %d 행 · 자막띠 교차 %d 프레임',
      execFrames, rows, crossFrames)
  if tiaBlind > 0 then
    say('0.5.116 ⚠ exec>0 인데 VDC 쓰기 0 인 프레임 %d 개 -- TIA 를 콜백이 못 본다.'
        .. ' vdc_* 무시하고 exec_* 만 읽을 것', tiaBlind)
  end
  if crossFrames == 0 then
    say('0.5.116 ⚠ 자막띠 교차가 0 이다.  띠(%d..%d)가 틀렸을 수 있으니'
        .. ' exec_min/exec_max 원자료로 다시 볼 것.  "찢김 없음" 으로 닫지 말 것',
        BAND_LO, BAND_HI)
  end
  say('0.5.116 저장 %s', PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.116-transfer-span-uncapped armed -- 순수 관측 · 게임 무수정 · 화면 무개입')
say('  0.5.115 는 히트 2040 에서 표본을 끊어 큰 버스트의 스팬을 잘라먹었다')
say('  이 판은 상한을 없애고 적응 간격으로 끝까지 따라간다')
say('  묻는 것 : 큰 버스트의 진짜 스팬 · 그 창이 자막 띠(%d..%d)를 가로지르는가',
    BAND_LO, BAND_HI)
say('  덤프 : ' .. PATH)
