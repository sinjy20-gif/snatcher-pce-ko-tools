-- SUB 0.5.115 -- 자막 전송/복원이 활성 표시 구간에 걸치는지 잰다 (쓰기 0 B)
--
-- 무엇을 가르려는가
-- ---------------------------------------------------------------------------
-- 2026-09-02 소유자 관측 두 장.
--
--     사진 1   조각이 바뀌는 순간   앞 자막 글자와 새 자막 글자가 x 격자로 뒤섞임
--     사진 2   자막이 사라지는 순간  가운데(자막 자리)에 글리프 잔해 띠
--
-- ★ 둘 다 **지속되지 않는다**.  소유자가 1 프레임으로 찰나를 잡은 것이다.
--   그래서 "안 지워서 남는다"(FRAGMENT_TEAR 기구 (가))로는 설명이 안 된다.
--   최종 상태는 깨끗하니 결국 누군가 정리를 한다.
--
-- 남는 설명은 (나) 다: **큰 VRAM 전송이 화면 그리는 중에 걸쳐서, 반쯤 쓰인
-- 상태가 한 프레임 보인다.**  전송이 vblank 안에서 끝나면 안 보일 것이다.
--
-- 이 판은 그 가설을 세우는 게 아니라 **재기만** 한다.  게임 무수정.
--
-- ★ 왜 VDC 쓰기가 아니라 exec 스팬이 주 측정인가
-- ---------------------------------------------------------------------------
-- 글리프 업로드는 `TIA $5D5A,$0002,128` 같은 블록 전송이다.  TIA 는 **한 명령**
-- 이라, 그것이 만드는 VDC 포트 쓰기가 Lua 쓰기 콜백을 안 태울 수 있다.
-- 그러면 writes=0 이 나오는데 그건 "전송이 없다" 가 아니라 **"못 봤다"** 다.
-- 0.5.2 머리말이 이미 경고한 함정이고, 그 판은 그래서 판정을 못 했다.
--
-- 우리 코드($5B80-$5E1F)의 **진입~이탈 스캔라인**은 그것과 무관하게 잡힌다.
-- 블록 전송이 길면 그 사이 스캔라인이 흐르므로 스팬에 그대로 나온다.
--
--     주 측정   exec 스팬    루틴이 몇 번째 줄에서 시작해 몇 번째 줄에 끝나나
--     보조      VDC 쓰기     잡히면 덤.  0 이어도 주 측정은 유효하다
--
-- 어떻게
-- ---------------------------------------------------------------------------
--     프레임마다  $5B80-$5E1F 의 exec 첫 줄 / 마지막 줄 / 히트 수
--                 VDC 포트($0000-$0003) 쓰기 첫 줄 / 마지막 줄 / 횟수
--                 그때의 STATE($7FDF) · 헬퍼 status($5D31) · ADPCM 재생 여부
--
--     span 은 (end - start + 263) % 263 로 낸다
--       ★ 0.4.70 이 이 보정을 안 해서 wrap 을 음수로 기록했다.  같은 실수 금지
--
--     getState 는 비싸다 (0.5.83 이 쓰기마다 불러 1 fps 가 됐다).
--     그래서 **표본 추출**한다 -- 첫 히트 + 8 번째마다, 버스트당 상한 256.
--     마지막 줄은 최대 8 명령 오차가 있는데, "표시 구간에 걸치나" 를 묻는 데는
--     충분하다.
--
-- 읽는 법 -- 판정표
-- ---------------------------------------------------------------------------
--     exec_where = VBlank        전송이 안전한 자리에서 끝난다
--                                -> (나) 기각.  다른 것을 봐야 한다
--     exec_where = 걸침          ★ 표시 구간에 걸친다 -> (나) 성립
--                                고칠 것은 "지우기" 가 아니라 **전송 타이밍**
--     exec_where = 표시          전송이 통째로 표시 구간 안이다.  (나) 강하게 성립
--
--     exec_hits = 0 인 프레임     우리 코드가 안 돈 프레임.  정상 (자막 없을 때)
--
--     ⚠ exec_hits > 0 인데 vdc_writes = 0
--       -> "전송이 없다" 가 **아니다**.  TIA 쓰기를 콜백이 못 본 것이다.
--          이 경우 vdc_* 칸은 전부 무시하고 exec_* 만 읽는다.
--          probe 는 이 상태를 tia_blind 로 따로 세어 끝에 보고한다.
--
-- 무엇을 보면 되나
-- ---------------------------------------------------------------------------
-- 두 순간의 행만 보면 된다.
--
--     state 1->2 로 바뀌는 프레임 근처   조각 전환 (사진 1)
--     state 3 인 프레임                  음성 종료 복원 (사진 2)
--
-- 그 행들의 exec_span 과 exec_where 가 답이다.
--
-- ★ 화면에 아무것도 안 그린다.  게임을 한 바이트도 안 고친다.
--
--   BIOS  build/patch/0.4.6.68/Syscard3_galmuri_0.4.6.68.pce
--   CUE   build/patch/0.4.6.68/Snatcher CD-ROMantic (Japan) [KO].cue
--   Power Cycle -> 이 파일만 로드 -> 국장실에서 대사 몇 개를 끝까지 흘린다
--                  (조각이 2개 이상인 음성이어야 전환이 잡힌다)
--
-- 산출물  C:/snatcher/dump/transfer_span_0_5_115_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local ENGINE_LO, ENGINE_HI = 0x5B80, 0x5E1F
local VDC_LO,    VDC_HI    = 0x0000, 0x0003

local STATE_ADDR  = 0x7FDF
local CTL_STATUS  = 0x5D31
local CTL_CMD     = 0x5D30

local LINES        = 263
local DISPLAY_LAST = 238            -- 이 위(239..262)는 VBlank 로 본다

local SAMPLE_EVERY = 8              -- 몇 히트마다 스캔라인을 뜨나
local SAMPLE_CAP   = 256            -- 버스트당 getState 상한

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/transfer_span_0_5_115_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tstate\tstatus\tcmd\tadpcm\t'
       .. 'exec_hits\texec_first\texec_last\texec_span\texec_where\t'
       .. 'vdc_writes\tvdc_first\tvdc_last\tvdc_span\tvdc_where\n')

local function say(f, ...) emu.log(string.format(f, ...)) end
local function rd(a)
  local ok, v = pcall(emu.read, a, MEM)
  return (ok and type(v) == 'number') and v or -1
end

-- 스캔라인 키 이름은 코어 판마다 다르다.  한 번만 찾아 기억한다 (0.4.70 방식)
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
      say('0.5.115 ⚠ 스캔라인 키를 못 찾았다 -- 이 판으로는 아무 판정도 하지 말 것')
    else
      say('0.5.115 스캔라인 키 = %s', LINE_KEY)
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

-- 한 줄이 표시 구간인가
local function isDisplay(l) return l >= 0 and l <= DISPLAY_LAST end

local function where(first, last)
  if first < 0 or last < 0 then return '-' end
  local a, b = isDisplay(first), isDisplay(last)
  if a and b then return '표시' end
  if not a and not b then return 'VBlank' end
  return '걸침'
end

local function span(first, last)
  if first < 0 or last < 0 then return -1 end
  return (last - first + LINES) % LINES
end

-- ---------------------------------------------------------------------------
-- 프레임 단위 수집기
-- ---------------------------------------------------------------------------
local frame = 0
local eHits, eFirst, eLast, eSamples = 0, -1, -1, 0
local vHits, vFirst, vLast, vSamples = 0, -1, -1, 0
local rows, tiaBlind, execFrames = 0, 0, 0

local function resetFrame()
  eHits, eFirst, eLast, eSamples = 0, -1, -1, 0
  vHits, vFirst, vLast, vSamples = 0, -1, -1, 0
end

-- 우리 코드 실행
emu.addMemoryCallback(function()
  eHits = eHits + 1
  if eSamples >= SAMPLE_CAP then return end
  if eHits == 1 or eHits % SAMPLE_EVERY == 0 then
    local l = scanline()
    eSamples = eSamples + 1
    if eFirst < 0 then eFirst = l end
    eLast = l
  end
end, emu.callbackType.exec, ENGINE_LO, ENGINE_HI, CPU, MEM)

-- VDC 포트 쓰기 (보조.  TIA 는 안 잡힐 수 있다)
emu.addMemoryCallback(function()
  vHits = vHits + 1
  if vSamples >= SAMPLE_CAP then return end
  if vHits == 1 or vHits % SAMPLE_EVERY == 0 then
    local l = scanline()
    vSamples = vSamples + 1
    if vFirst < 0 then vFirst = l end
    vLast = l
  end
end, emu.callbackType.write, VDC_LO, VDC_HI, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  if eHits > 0 then
    execFrames = execFrames + 1
    if vHits == 0 then tiaBlind = tiaBlind + 1 end

    local eW = where(eFirst, eLast)
    out:write(string.format(
      '%d\t%d\t%d\t%d\t%s\t%d\t%d\t%d\t%d\t%s\t%d\t%d\t%d\t%d\t%s\n',
      frame, rd(STATE_ADDR), rd(CTL_STATUS), rd(CTL_CMD), adpcmOn(),
      eHits, eFirst, eLast, span(eFirst, eLast), eW,
      vHits, vFirst, vLast, span(vFirst, vLast), where(vFirst, vLast)))
    out:flush()
    rows = rows + 1

    -- 큰 전송만 골라 즉시 보고한다 (조각 전환·복원이 여기 걸린다)
    if rows <= 40 or eHits >= 400 then
      say('0.5.115 f%d state=%d hits=%d  %d->%d  span=%d  %s   (vdc %d)',
          frame, rd(STATE_ADDR), eHits, eFirst, eLast,
          span(eFirst, eLast), eW, vHits)
    end
  end
  resetFrame()
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:close()
  say('0.5.115 끝 -- 우리 코드가 돈 프레임 %d · 기록 %d 행', execFrames, rows)
  if tiaBlind > 0 then
    say('0.5.115 ⚠ exec>0 인데 VDC 쓰기 0 인 프레임 %d 개 -- TIA 쓰기를 콜백이 못 본다.'
        .. ' vdc_* 칸은 무시하고 exec_* 만 읽을 것', tiaBlind)
  end
  say('0.5.115 저장 %s', PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.115-transfer-span armed -- 순수 관측 · 게임 무수정 · 화면 무개입')
say('  묻는 것 : 자막 전송/복원이 활성 표시 구간(line 0..%d)에 걸치는가', DISPLAY_LAST)
say('  주 측정 : $5B80-$5E1F exec 스팬 (TIA 가 쓰기 콜백을 안 태워도 유효)')
say('  볼 행   : state 가 1->2 로 바뀌는 프레임(조각 전환) · state 3 (종료 복원)')
say('  덤프 : ' .. PATH)
