-- SUB 0.5.33 -- ADPCM 음성의 LBA 가 콘솔 RAM 어디에 있는가.  수집값과 맞는가
--
-- 왜 이걸 재나
-- ---------------------------------------------------------------------------
-- 지금까지 런타임 식별은 6 B 키(end+rate+ADPCM RAM 3표본)로 하기로 돼 있었다.
-- 그런데 그 3표본을 콘솔에서 뜨려면 ADPCM 포트를 건드려야 하고, 그것이 재생을
-- 교란하는지는 **아무도 안 쟀다.**  유일하게 남은 미측정 위험이었다.
--
-- 그런데 CD-DA 가 `$26F9`(트랙 번호) 한 바이트로 식별하듯, ADPCM 에도 대응물이
-- 있다 -- **섹터(LBA)** 다.  수집표로 검증했다.
--
--     1055 행 · 고유 섹터 1047 · 고유 6B키 1025
--     한 섹터가 2 개 이상 키를 가리키는 경우:  5       <- 사실상 1:1
--     (시작,끝,rate) 로는 251 번 충돌한다 -- 주소는 그릇이지 정체성이 아니다.
--      같은 ADPCM 버퍼를 최대 10 개 음성이 돌려 쓴다)
--
-- 그리고 정적 분석으로 그 LBA 가 평범한 RAM 에 있다는 것이 나왔다.
--
-- AD_TRANS ($E033 -> $F393) 가 SCSI 명령을 조립한다
-- ---------------------------------------------------------------------------
-- ```
-- $F3B1  JSR $F0EE            ; $224C..$2254 (CDB 9 B) 0으로 지움
-- $F3B4  LDA #$08 / STA $224C ; SCSI opcode $08 = READ(6)
-- $F3B9  JSR $F104            ; LBA 산술 ($FD/$FE 를 다음 섹터로 전진)
-- $F3BC  LDX #$04 / LDY #$01
-- $F3C0  JSR $F327            ; ★ LBA 3 B 복사
-- $F3C3  LDA $F8 / STA $2250  ; 전송 섹터 수
-- $F3C8  JSR $E900            ; 명령 발행
--
-- $F327  LDA $F8,X / STA $224C,Y     X=4, Y=1 이므로
--        LDA $F9,X / STA $224D,Y  ->   $FC -> $224D
--        LDA $FA,X / STA $224E,Y       $FD -> $224E
--        RTS                           $FE -> $224F
-- ```
--
--     호출자 규약   제로페이지 $FC/$FD/$FE  = 24-bit LBA (MSB first)
--     BIOS 사본     $224D/$224E/$224F       = SCSI CDB 의 LBA 칸
--
-- ★ 제로페이지는 물리적으로 $2000-$20FF 다.  그래서 $FC 는 $20FC 로 읽는다.
--
-- 가정하지 않고 재야 할 것 두 가지
-- ---------------------------------------------------------------------------
--   1) AD_TRANS 는 **루프**다 ($F3F4 BCC $F3A3).  매 회 $F104 가 LBA 를 전진시킨다.
--      전송이 끝난 시점의 $224D-$224F 는 그 음성의 **첫 섹터가 아니라 마지막**이다.
--      수집기(`cdrom.scsi.sector`)가 어느 쪽과 같은지는 **확인 대상**이다.
--      -> 그래서 첫 섹터와 마지막 섹터를 **둘 다** 잡는다.
--
--   2) CDB 는 모든 CD 읽기가 덮어쓴다 (그림·스크립트 포함).
--      -> 재생 시점의 라이브 값도 같이 적어 얼마나 오염되는지 본다.
--
-- 무엇을 찍나 -- 음성 한 개당 한 줄
-- ---------------------------------------------------------------------------
--     lba_first / lba_last    직전 AD_TRANS 의 첫·마지막 CDB LBA
--     zp_at_entry             AD_TRANS 진입 시점의 $FC/$FD/$FE (BIOS 산술 전)
--     lba_live                재생 시작 순간 $224D-$224F 를 그냥 읽은 값
--     scsi_sector             cdrom.scsi.sector (수집기가 쓴 에뮬 값)
--     key                     6 B 런타임 키 -- 수집표와 조인하는 열쇠
--
-- 이 다섯이 한 줄에 있으면 **어느 것이 수집표의 sector 와 맞는지 오프라인으로
-- 판정**된다.  맞는 것이 있으면 런타임 식별은 3 B RAM 읽기로 끝난다.
--
-- 읽기 전용이다.  ADPCM 포트를 건드리지 않고, 아무 주소에도 쓰지 않고,
-- 화면에 아무것도 그리지 않는다.
--
-- Power Cycle 뒤 이 파일 하나만 로드한다 (0.4.93 금지 -- 그 아래 0.4.31 이
-- $22A6/$22A7/$22AA 를 위조해 키가 오염된다).
--
--     CUE  build/patch/0.4.6.22-dictionary-key-vram/...[KO].cue
--
-- ★ 음성을 여러 개 받을 것.  많을수록 판정이 단단해진다.

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local APCM = emu.memType.pceAdpcmRam

local AD_TRANS   = 0xF393     -- 진입
local CMD_ISSUE  = 0xF3C8     -- JSR $E900 -- 이 순간 CDB 에 이번 회 LBA 가 있다
local CDB_LBA    = 0x224D     -- $224D/$224E/$224F  (MSB first)
local ZP_LBA     = 0x20FC     -- 제로페이지 $FC/$FD/$FE -> 물리 $20FC

local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/adpcm_lba_source_0_5_33_' .. STAMP .. '.tsv'
local out = io.open(OUT, 'w')
if out then
  out:write('voice\tframe\tkey\tlba_first\tlba_last\tzp_at_entry\tlba_live\t' ..
            'scsi_sector\tsectors\ttrans_frame\tgap\n')
end

local function rb(a) return emu.read(a, MEM) or 0 end

-- 24-bit MSB-first 3 B 를 정수로
local function lba24(base)
  return (rb(base) << 16) | (rb(base + 1) << 8) | rb(base + 2)
end

local function st()
  local ok, s = pcall(emu.getState)
  if not ok or type(s) ~= 'table' then return nil end
  return s
end

local function num(s, k)
  local v = s and s[k]
  return type(v) == 'number' and math.floor(v) or -1
end

-- ---------------------------------------------------------------------------
-- AD_TRANS 추적 -- 첫 섹터와 마지막 섹터를 둘 다 잡는다
-- ---------------------------------------------------------------------------
local frame = 0
local cur = nil          -- 진행 중인 전송
local last = nil         -- 직전에 끝난(또는 진행 중인) 전송의 결과

emu.addMemoryCallback(function()
  -- 진입: BIOS 산술이 돌기 전의 호출자 LBA 를 뜬다
  cur = { first = -1, last = -1, n = 0, zp = lba24(ZP_LBA), frame = frame }
end, emu.callbackType.exec, AD_TRANS, AD_TRANS, CPU, MEM)

emu.addMemoryCallback(function()
  -- 명령 발행 직전: 이번 회 CDB LBA
  local v = lba24(CDB_LBA)
  if not cur then
    cur = { first = -1, last = -1, n = 0, zp = -1, frame = frame }
  end
  if cur.n == 0 then cur.first = v end
  cur.last = v
  cur.n = cur.n + 1
  last = cur
end, emu.callbackType.exec, CMD_ISSUE, CMD_ISSUE, CPU, MEM)

-- ---------------------------------------------------------------------------
-- 음성 시작 -- 한 줄 찍는다
-- ---------------------------------------------------------------------------
local function hex6(k)
  return (k:gsub('.', function(c) return string.format('%02X', c:byte()) end))
end

local voices, prevPlaying = 0, false

emu.addEventCallback(function()
  frame = frame + 1
  local s = st()
  if not s then return end

  local playing = s['cdrom.adpcm.playing'] == true
  if playing and not prevPlaying then
    voices = voices + 1

    -- 6 B 런타임 키 -- 수집기/0.4.31 과 정확히 같은 정의
    local ra   = num(s, 'cdrom.adpcm.readAddress')
    local len  = num(s, 'cdrom.adpcm.adpcmLength')
    local rate = num(s, 'cdrom.adpcm.playbackRate') & 0xFF
    local fin  = (ra + len) & 0xFFFF
    local key  = string.char(fin & 0xFF, (fin >> 8) & 0xFF, rate,
                             emu.read(fin // 4, APCM) or 0,
                             emu.read(fin // 2, APCM) or 0,
                             emu.read((fin * 5) // 8, APCM) or 0)

    local t = last or { first = -1, last = -1, n = 0, zp = -1, frame = -1 }
    local live = lba24(CDB_LBA)
    local scsi = num(s, 'cdrom.scsi.sector')

    local row = string.format(
      '%d\t%d\t%s\t%06X\t%06X\t%06X\t%06X\t%s\t%d\t%d\t%d\n',
      voices, frame, hex6(key),
      t.first & 0xFFFFFF, t.last & 0xFFFFFF, t.zp & 0xFFFFFF, live,
      scsi >= 0 and string.format('%06X', scsi) or '??????',
      t.n, t.frame, t.frame >= 0 and (frame - t.frame) or -1)
    if out then out:write(row); out:flush() end

    emu.log(string.format(
      'SUB 0.5.33 ★ VOICE #%d key %s · first %06X · last %06X · zp %06X · live %06X · scsi %s (%d섹터, %d프레임 전)',
      voices, hex6(key), t.first & 0xFFFFFF, t.last & 0xFFFFFF, t.zp & 0xFFFFFF, live,
      scsi >= 0 and string.format('%06X', scsi) or '??????',
      t.n, t.frame >= 0 and (frame - t.frame) or -1))

    if voices == 1 and t.n == 0 then
      emu.log('SUB 0.5.33 ⚠ AD_TRANS 가 한 번도 안 잡혔다.')
      emu.log('   이 음성은 AD_TRANS 가 아닌 경로로 올라왔거나, 훅 주소가 이 BIOS 와 다르다.')
      emu.log('   ($F393 / $F3C8 은 0.4.6.22 이미지 기준이다)')
    end
  end
  prevPlaying = playing
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if out then out:close() end
  emu.log(string.format('SUB 0.5.33 끝 -- 음성 %d 개 · %s', voices, OUT))
end, emu.eventType.scriptEnded)

emu.log('SUB 0.5.33-adpcm-lba-source armed -- 읽기 전용.  ADPCM 포트 안 건드린다')
emu.log('  AD_TRANS $F393 진입 · 명령발행 $F3C8 에서 CDB LBA($224D-$224F)를 잡는다')
emu.log('  ★ 판정: lba_first / lba_last / zp_at_entry / lba_live 중 무엇이')
emu.log('         수집표(voice_console_keys.tsv)의 sector 와 맞는가')
emu.log('  ★ 맞는 것이 있으면 런타임 식별은 3 B RAM 읽기로 끝난다')
emu.log('  ★ 음성 여러 개 · 끝나면 Lua 창 Stop')
emu.log('  로그: ' .. OUT)
