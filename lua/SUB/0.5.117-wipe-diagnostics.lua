-- SUB 0.5.117 -- 복원 직전 SATB wipe 가 실제로 먹는지 읽는다 (쓰기 0 B)
--
-- 어디까지 왔나
-- ---------------------------------------------------------------------------
-- 0.5.115/0.5.116 으로 확정된 것:
--
--     복원 버스트   13,815 명령 · 155 스캔라인 (프레임의 59%) · 자막 띠를 가로지름
--     전송이 VBlank 에 들어가는 일이 없다.  전부 활성 표시 구간이다
--
-- 그리고 `build_subtitle_vram_helper.py` 머리말이 이 증상을 이미 적어두었다:
--
--     "복원은 표시 구간 한복판에서 VRAM 을 덮는다.  그 사이 우리 자막
--      스프라이트가 그 자리를 패턴 소스로 가리키고 있으면, 그 프레임에
--      복원 중인 데이터를 글자로 그린다 -- 대사 자리에 1 프레임짜리
--      깨진 화면이 뜬다 (0.5.9/0.5.10 으로 확정)"
--
-- 대책도 이미 들어가 있다 -- 복원 진입 직후 `JSR wipe_sprites`.
-- 소스에도 있고 현재 빌드에도 있다.  그런데 소유자는 여전히 그 화면을 본다.
--
-- 그래서 이 판이 묻는 것은 하나다: **그 wipe 가 왜 안 먹나.**
--
-- 헬퍼가 스스로 남기는 진단값
-- ---------------------------------------------------------------------------
-- wipe_sprites 는 SATB 주소를 하드코딩하지 않는다.  후보 주소를 훑되 "패턴이
-- 우리 글리프 블록을 가리키고 팔레트가 $F 인" 슬롯만 지운다.  그래서 주소가
-- 틀려도 무해하지만, **아무것도 안 지우고 끝날 수 있다.**
--
--     $5D32  wipe_seen   비어 있지 않던 슬롯 수
--     $5D33  wipe_done   실제로 지운 슬롯 수
--
-- 판정
-- ---------------------------------------------------------------------------
--     seen = 0                그 주소는 SATB 가 아니다.  wipe 가 헛돈다
--                             -> 고칠 곳은 wipe 대상 주소
--     seen > 0 · done = 0     SATB 는 맞는데 우리 자막 슬롯이 없다
--                             -> 자막이 스프라이트가 아니라 BG 로 그려진다는 뜻
--                             -> wipe 노선 자체가 이 증상에 안 맞는다
--     seen > 0 · done > 0     wipe 는 제대로 먹었다
--                             -> ★ 그런데도 깨지면 잔해는 스프라이트가 아니다.
--                                복원 중인 VRAM 을 BG 가 직접 그리는 것이다
--                                -> 남은 길은 전송 타이밍(쪼개기/vblank) 뿐
--
-- ★ 셋 다 "다음에 뭘 고칠지" 가 다르다.  그래서 이걸 먼저 읽는다.
--
-- 어떻게
-- ---------------------------------------------------------------------------
-- 복원 프레임을 exec 히트 수로 집어낸다 (복원은 13,000+ 히트라 다른 것과 안 섞인다).
-- 그 프레임의 seen/done/status 를 그대로 찍는다.
--
--   ⚠ seen/done 은 헬퍼가 **복원 때마다 새로 쓴다**.  endFrame 에 읽으므로
--     그 프레임에 복원이 돌았다면 그 값이다.  복원이 없던 프레임의 값은
--     직전 복원의 잔값이므로, 히트 수로 거른 행만 믿을 것.
--
-- ★ 화면에 아무것도 안 그린다.  게임을 한 바이트도 안 고친다.
--
--   BIOS  build/patch/0.4.6.68/Syscard3_galmuri_0.4.6.68.pce
--   CUE   build/patch/0.4.6.68/Snatcher CD-ROMantic (Japan) [KO].cue
--   Power Cycle -> 이 파일만 로드 -> 대사를 **끝까지** 흘린다 (종료 복원을 봐야 한다)
--
-- 산출물  C:/snatcher/dump/wipe_diag_0_5_117_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local ENGINE_LO, ENGINE_HI = 0x5B80, 0x5E1F

-- subtitle_layout.py: HELPER_CTL = 슬롯끝-16 = $5B80+432 = $5D30
local CTL_COMMAND   = 0x5D30
local CTL_STATUS    = 0x5D31
local CTL_WIPE_SEEN = 0x5D32
local CTL_WIPE_DONE = 0x5D33
local CTL_VRAM_LO   = 0x5D34
local CTL_VRAM_HI   = 0x5D35
local STATE_ADDR    = 0x7FDF

local BIG_HITS = 4000        -- 이 이상이면 복원 버스트로 본다 (실측 13,800)

local LINES = 263
local BAND_LO, BAND_HI = 118, 145

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/wipe_diag_0_5_117_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tkind\tstate\tstatus\tcmd\twipe_seen\twipe_done\tvram_base\t'
       .. 'exec_hits\texec_min\texec_max\texec_span\tcrosses\n')

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
  end
  if LINE_KEY == false then return -1 end
  local v = s[LINE_KEY]
  return type(v) == 'number' and math.floor(v) or -1
end

local function everyFor(h)
  if h <= 512 then return 8 end
  if h <= 4096 then return 64 end
  return 256
end

local frame = 0
local hits, lmin, lmax, lfirst, llast = 0, -1, -1, -1, -1
local restores, seenZero, doneZero, bothOk = 0, 0, 0, 0

emu.addMemoryCallback(function()
  hits = hits + 1
  if hits == 1 or hits % everyFor(hits) == 0 then
    local l = scanline()
    if l >= 0 then
      if lfirst < 0 then lfirst = l end
      llast = l
      if lmin < 0 or l < lmin then lmin = l end
      if lmax < 0 or l > lmax then lmax = l end
    end
  end
end, emu.callbackType.exec, ENGINE_LO, ENGINE_HI, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  if hits > 0 then
    local kind = (hits >= BIG_HITS) and '복원' or '기타'
    local seen, done = rd(CTL_WIPE_SEEN), rd(CTL_WIPE_DONE)
    local base = string.format('%02X%02X', rd(CTL_VRAM_HI), rd(CTL_VRAM_LO))
    local crosses = '-'
    if lmin >= 0 and lmax >= 0 then
      crosses = (lmin <= BAND_HI and lmax >= BAND_LO) and 'YES' or 'no'
    end
    local sp = (lfirst >= 0 and llast >= 0) and ((llast - lfirst + LINES) % LINES) or -1

    if kind == '복원' or hits >= 400 then
      out:write(string.format('%d\t%s\t%d\t%d\t%d\t%d\t%d\t%s\t%d\t%d\t%d\t%d\t%s\n',
        frame, kind, rd(STATE_ADDR), rd(CTL_STATUS), rd(CTL_COMMAND),
        seen, done, base, hits, lmin, lmax, sp, crosses))
      out:flush()
    end

    if kind == '복원' then
      restores = restores + 1
      if seen == 0 then seenZero = seenZero + 1
      elseif done == 0 then doneZero = doneZero + 1
      else bothOk = bothOk + 1 end
      say('0.5.117 f%d ★복원 hits=%d %d..%d span=%d 교차=%s  base=%s'
          .. '  wipe seen=%d done=%d  status=%d',
          frame, hits, lmin, lmax, sp, crosses, base, seen, done, rd(CTL_STATUS))
    end
  end
  hits, lmin, lmax, lfirst, llast = 0, -1, -1, -1, -1
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:close()
  say('0.5.117 끝 -- 복원 %d 회', restores)
  if restores == 0 then
    say('0.5.117 ⚠ 복원을 한 번도 못 봤다.  대사를 끝까지 안 흘렸거나 히트 문턱(%d)이'
        .. ' 높다.  아무 판정도 하지 말 것', BIG_HITS)
  else
    say('0.5.117   seen=0 %d 회 -> wipe 대상 주소가 SATB 가 아니다', seenZero)
    say('0.5.117   seen>0 done=0 %d 회 -> 자막이 스프라이트가 아니다.'
        .. ' wipe 노선이 이 증상에 안 맞는다', doneZero)
    say('0.5.117   seen>0 done>0 %d 회 -> wipe 는 먹었다.'
        .. ' 그래도 깨지면 잔해는 BG 다 -> 남은 길은 전송 타이밍', bothOk)
  end
  say('0.5.117 저장 %s', PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.117-wipe-diagnostics armed -- 순수 관측 · 게임 무수정 · 화면 무개입')
say('  묻는 것 : 복원 직전 SATB wipe 가 실제로 슬롯을 지우는가')
say('  $5D32 wipe_seen · $5D33 wipe_done 을 복원 프레임에서 읽는다')
say('  덤프 : ' .. PATH)
