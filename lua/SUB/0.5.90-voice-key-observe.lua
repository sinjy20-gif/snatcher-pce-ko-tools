-- SUB 0.5.90 -- 음성 키를 재생 순간 그대로 관측한다 (역산 없음)
--
-- 왜 새로 만드나
-- ---------------------------------------------------------------------------
-- 기존 수집기는 값을 **역산**한다.
--
--     endAddress = (readAddress + adpcmLength) % 64KB
--     start_lba  = key 의 sector - ceil(adpcmLength / 2048)      (색인 빌더)
--
-- `adpcmLength` 는 16 비트 하드웨어 레지스터다.  64 KB 를 넘는 음성은 버퍼를
-- 거의 꽉 채우므로 `FFBx` 근처가 되고, 그러면
--
--     endAddress 가 FFFF 로 수렴한다        -> 키가 ADPCM_xxxxxx_FFFF_xx
--     그 길이로 start_lba 를 되짚으면 밀린다 -> 최대 94 섹터 (실측 ADPCM_00359E)
--
-- 이 판은 되짚지 않는다.  **재생이 시작된 그 순간의 값을 그대로 적는다.**
--
-- 무엇을 적나
-- ---------------------------------------------------------------------------
--     start_sector      재생 시작 순간의 cdrom.scsi.sector      <- 역산 안 함
--     read/write/len/rate  하드웨어 레지스터 원값
--     end_address       기존 규칙대로 계산한 값 (키 대조용)
--     bytes_total       Lua 에서 32 비트로 누적한 실제 전송량
--     frames            재생 프레임 수
--
-- ★ 중복 제거를 하지 않는다.  같은 키가 여러 번 나와도 매번 적는다.
--   기존 수집기가 `existing_key` 로 건너뛰면서 64 KB 에서 멈춘 건이 있었다
--   (7 건이 8.17 초 · 65,4xx B 에 몰려 있었다).  그 함정을 피한다.
--
-- ★ 게임을 한 바이트도 안 고친다.  화면에 아무것도 안 그린다.
-- ★ 어느 빌드로 돌려도 된다.  자막이 나오든 말든 관측만 한다.
--
-- 돌리는 법
--     아무 빌드로 Power Cycle -> 이 파일 하나만 로드 -> 평소처럼 진행
--     자막 확인하며 돌면 그 김에 키가 쌓인다
--
-- 산출물  C:/snatcher/dump/voice_key_observe_0_5_90_<시각>.tsv

local RAM_SIZE = 0x10000

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/voice_key_observe_0_5_90_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('seq\tkey\tstart_sector\tstart_frame\tend_frame\tframes\t'
       .. 'read_addr\twrite_addr\tadpcm_len\trate\tend_addr\tbytes_total\tptr_mode\n')

local frame, seq = 0, 0
local active = nil

local function say(f, ...) emu.log(string.format(f, ...)) end

local function num(s, key)
  local v = s and s[key]
  return type(v) == 'number' and math.floor(v) or 0
end

local function state()
  local ok, s = pcall(emu.getState)
  return ok and s or nil
end

-- 재생 중인가 -- 기존 수집기와 같은 판정 지점
local function playing(s)
  local v = s and (s['cdrom.adpcm.playing'] or s['cdrom.adpcm.isPlaying'])
  if type(v) == 'boolean' then return v end
  if type(v) == 'number' then return v ~= 0 end
  return nil
end

local function startOf(s)
  local read  = num(s, 'cdrom.adpcm.readAddress')
  local write = num(s, 'cdrom.adpcm.writeAddress')
  local len   = num(s, 'cdrom.adpcm.adpcmLength')
  local rate  = num(s, 'cdrom.adpcm.playbackRate')
  local sect  = num(s, 'cdrom.scsi.sector')
  local endAddr = (read + len) % RAM_SIZE
  seq = seq + 1
  return {
    seq = seq, sector = sect, read = read, write = write, len = len,
    rate = rate, endAddr = endAddr, startFrame = frame,
    prev = read, bytes = 0, mode = 'read', modeFrames = 0,
    firstRead = read, firstWrite = write,
    key = string.format('ADPCM_%06X_%04X_%02X', sect, endAddr, rate),
  }
end

local function finish(s)
  if not active then return end
  local a = active
  active = nil
  out:write(string.format(
    '%d\t%s\t%06X\t%d\t%d\t%d\t%04X\t%04X\t%04X\t%02X\t%04X\t%d\t%s\n',
    a.seq, a.key, a.sector, a.startFrame, frame, frame - a.startFrame,
    a.read, a.write, a.len, a.rate, a.endAddr, a.bytes, a.mode))
  out:flush()
  say('0.5.90 %s  섹터 %06X · %d 프레임 · %d B%s',
      a.key, a.sector, frame - a.startFrame, a.bytes,
      a.bytes > 65535 and '  ★64KB 초과' or '')
end

emu.addEventCallback(function()
  frame = frame + 1
  local s = state()
  if not s then return end
  local on = playing(s)
  if on == nil then return end            -- 판정 못 하면 아무것도 안 한다

  if on and not active then
    active = startOf(s)
    say('0.5.90 ▶ %s  시작 섹터 %06X · len %04X · rate %02X',
        active.key, active.sector, active.len, active.rate)
  elseif on and active then
    -- read 가 안 움직이면 write 추적으로 갈아탄다 (기존 수집기와 같은 규칙)
    local r = num(s, 'cdrom.adpcm.readAddress')
    local w = num(s, 'cdrom.adpcm.writeAddress')
    if active.mode == 'read' and active.modeFrames < 30 then
      active.modeFrames = active.modeFrames + 1
      if active.modeFrames == 30 and r == active.firstRead and w ~= active.firstWrite then
        active.mode = 'write'
        active.prev = w
      end
    end
    local p = (active.mode == 'read') and r or w
    local step = (p - active.prev) % RAM_SIZE
    if step > 0 and step < RAM_SIZE // 2 then      -- 정상 전진만 더한다
      active.bytes = active.bytes + step           -- ★ Lua 정수라 64KB 에서 안 멈춘다
      active.prev = p
    end
  elseif (not on) and active then
    finish(s)
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if active then finish(state()) end
  out:close()
  say('0.5.90 끝 -- %d 건 관측 · 저장 %s', seq, PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.90-voice-key-observe armed -- 순수 관측 · 게임 무수정')
say('  재생 순간의 값을 그대로 적는다 (역산 없음 · 중복 제거 없음)')
say('  덤프 : ' .. PATH)
