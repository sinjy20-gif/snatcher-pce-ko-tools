-- SUB 0.5.142 -- 오버사이즈 음성은 다른 경로로 재생을 시작하는가
--
-- ★ 순수 관측.  아무것도 안 고친다.  게임 무수정.
--
-- 가설 (소유자)
-- ---------------------------------------------------------------------------
-- "오버사이즈 음성만 다른 경로인건가?"  -- 증거 둘이 같은 방향을 가리킨다:
--
--     1  $22A6/$22A7 가 안 갱신된다   -> BIOS 셋업 루틴($F5D8~)이 안 돌았다
--     2  A1 도 A0 도 안 뜬다          -> LBA 포착 훅이 안 돌았다   (0.5.141)
--
-- 둘 다 "평범한 ADPCM 시작 경로" 에 얹혀 있다.  그게 통째로 안 돌았다면
-- FFFF 음성은 **다른 경로로 재생을 시작한다**.  그 하나면 "왜 FFFF 만" 이 풀린다.
--
-- 알려진 경로 (BASELINE_2026-08-30 §측정 2)
-- ---------------------------------------------------------------------------
--     $F5D8  LDA $FA / STA $22A8      셋업 시작
--     $F5E2  LDA $F8 / STA $22A6      ★ finish 하위   <- 여기가 안 돌았다
--     $F5EC  LDA $FF / CMP #$10 / BCS $F61E    ★ 여기서 빠지는 갈래가 있다
--     $F601  ... JSR $F729 / JSR $F71E         읽기 포인터 확정
--     $F618  LDA #$60 / STA $180D              ★ 재생 시작
--
-- 무엇을 적나
-- ---------------------------------------------------------------------------
--     $180D 쓰기를 전부 · 그때의 PC 와 값
--     $22A6/$22A7 쓰기를 전부 · 그때의 PC        <- 갱신이 어디서 되는지
--     재생 시작 프레임 · 길이 포화 여부
--
-- 판정
--     SAT 음성의 $180D writer PC 가 다른 값이다   -> ★ 다른 경로 확정.  거기가 답이다
--     같은 PC 인데 $22A6 쓰기만 없다              -> 셋업 앞부분만 건너뛴다
--     $180D 쓰기가 아예 안 잡힌다                 -> DMA/다른 방식으로 시작한다
--
-- ★ 상한 없음.  잘릴 일이 없다 (인계서 §2-1)
--
-- 산출물  C:/snatcher/dump/play_path_0_5_142_<시각>.tsv

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/play_path_0_5_142_' .. STAMP .. '.tsv'

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local CTRL   = 0x180D
local K_LO, K_HI, K_RATE = 0x22A6, 0x22A7, 0x22AA

local out = io.open(PATH, 'w')
out:write('frame\tkind\tpc\tvalue\tlen\tsat\tkey\tnote\n')
local function say(m) emu.log(m); print(m) end
local function num(s,k) local v = s and s[k]; return type(v)=='number' and v or 0 end
local function rd(a) local ok,v = pcall(emu.read, a, MEM); return ok and v or 0 end

local PC_KEY = nil
local function pcNow()
  local ok, s = pcall(emu.getState)
  if not ok or not s then return -1 end
  if PC_KEY == nil then
    PC_KEY = false
    for _, k in ipairs({ 'cpu.pc', 'pc' }) do
      if type(s[k]) == 'number' then PC_KEY = k break end
    end
  end
  if PC_KEY == false then return -1 end
  local v = s[PC_KEY]
  return type(v) == 'number' and math.floor(v) or -1
end

local frame, playing = 0, false
local pending = {}          -- 이번 재생 직전에 본 것들

local function keyNow()
  return ('%02X%02X%02X'):format(rd(K_HI) & 0xFF, rd(K_LO) & 0xFF, rd(K_RATE) & 0xFF)
end

emu.addMemoryCallback(function(address, value)
  local pc = pcNow()
  value = (value or 0) & 0xFF
  pending[#pending+1] = { kind = 'CTRL', pc = pc, v = value, frame = frame }
  out:write(('%d\tCTRL\t%04X\t%02X\t\t\t%s\t$180D 쓰기\n'):format(frame, pc, value, keyNow()))
end, emu.callbackType.write, CTRL, CTRL, CPU, MEM)

emu.addMemoryCallback(function(address, value)
  local pc = pcNow()
  pending[#pending+1] = { kind = 'KEYW', pc = pc, v = (value or 0) & 0xFF, frame = frame,
                          addr = address }
  out:write(('%d\tKEYW\t%04X\t%02X\t\t\t\t$%04X 쓰기\n'):format(
    frame, pc, (value or 0) & 0xFF, address))
end, emu.callbackType.write, K_LO, K_HI, CPU, MEM)

local function onFrame()
  frame = frame + 1
  local ok, s = pcall(emu.getState)
  if not ok or not s then return end
  local isPlay = s['cdrom.adpcm.playing']
  if isPlay == nil then isPlay = s['cdrom.adpcm.isPlaying'] end
  isPlay = isPlay and true or false

  if isPlay and not playing then
    local len = num(s, 'cdrom.adpcm.adpcmLength')
    local sat = (len >= 0xFF00) and 'SAT' or ''
    out:write(('%d\tPLAY\t\t\t%04X\t%s\t%s\t재생 시작\n'):format(frame, len, sat, keyNow()))
    say(('%s PLAY f%-6d len=%04X key=%s'):format(
      sat == '' and '     ' or '★SAT', frame, len, keyNow()))
    -- 직전에 본 것들을 되짚어 보여준다
    local shown = 0
    for i = #pending, 1, -1 do
      local e = pending[i]
      if frame - e.frame > 120 then break end
      shown = shown + 1
      if shown <= 10 then
        say(('        %s pc=$%04X v=%02X (f%d)'):format(e.kind, e.pc, e.v, e.frame))
      end
    end
    if shown == 0 then say('        (직전 120 프레임에 $180D·$22A6 쓰기가 없다)') end
    pending = {}
    out:flush()
  end
  playing = isPlay
  if #pending > 400 then pending = {} end
end

emu.addEventCallback(onFrame, emu.eventType.endFrame)
emu.addEventCallback(function() out:close() end, emu.eventType.scriptEnded)
say('SUB 0.5.142-play-path armed -- 순수 관측')
say('  ★ 볼 것: ★SAT 의 $180D writer PC 가 정상 음성과 다른가')
say('  ' .. PATH)
