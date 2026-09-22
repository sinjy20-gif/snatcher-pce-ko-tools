-- PROBE_SAT_EXTEND 0.1.0  --  빼앗지 말고 늘린다
--
-- 왜
-- --
-- PROBE_SAT_HIJACK 0.1.0 은 $6500 에서 게임 엔트리를 우리 것으로 바꿔치기해
-- 글자를 띄웠다.  성공했지만 게임 스프라이트 하나를 빼앗았다 (길리언 눈에
-- 검은 띠).  이 판은 빼앗지 않는다.
--
-- 정적 디스어셈블로 SATB 조립 전체가 드러났다 (Track02 섹터 251, $6000 베이스)
--
--   6008  ST1 #$00 / ST2 #$10     MAWR = VDC 워드 $1000 = SATB
--   601E  LDA #$3F / STA $17      ★ $17 = 전역 슬롯 예산 63
--   6022-603B  객체 루프 A  X=$00..$1F   JSR $63CB
--   6044-606D  객체 루프 B  X=$20..$3F
--   6072  JMP $43BE              ★ 조립 전체의 끝
--
--   6459  LDA ($10) / STA $16    $16 = 리스트 머리의 개수 바이트
--   6463  엔트리 파서 (5 바이트 고정)
--   6500  zp $00-$07 을 VWR 로 푸시
--   6512  DEC $17 / BMI $6527    예산 소진이면 종료
--   6520  DEC $16 / BEQ $6527    이 리스트 소진이면 종료
--
-- $6072 에 닿는 순간 게임은 자기 슬롯을 다 썼고 $17 에 남은 예산이 있다.
-- $6000-$7FFF 는 CD-RAM 이므로 그 JMP 를 우리 스텁으로 갈아끼울 수 있다.
-- 스텁은 원점 zp $08-$0F 를 세우고 게임의 $6463 을 JSR 한다.
-- **게임이 자기 손으로 민다.  그래서 안 지워진다.  그리고 아무것도 안 빼앗는다.**
--
-- 5 바이트 레코드 형식 ($63CB + $6463 파서에서 확정)
--   [0] attr 상위 (크기·플립).  bit7=1 이면 3바이트 재연결 레코드
--   [1] Y 오프셋 (부호) -> zp $08/$09 원점에 더함
--   [2] X 오프셋 (부호) -> zp $0A/$0B 원점에 더함
--   [3] 패턴 하위 바이트
--   [4] bit7=우선순위 · bits6-4=패턴 상위 · bits3-0=팔레트   ($0E=0 일 때)
--
-- 전제: SUBTITEL 0.2.13 페이로드 (패턴이 VRAM 워드 $7900 에 올라가고
--       스프라이트 팔레트 0 의 색 1·2 가 세팅된다).  AC 적재는 이 판이 같이 한다.
--
-- 성공 판정
--   화면에 글리프가 뜨고 **길리언 얼굴이 멀쩡하면** 성공.
--
-- 출력  로그 + C:/snatcher/dump/probe_sat_extend_0_1_0_<날짜>.tsv
--       ★ scriptEnded 뿐 아니라 300 프레임마다 흘려 쓴다.
--         (0.1.0 히잭 판은 Mesen 을 그냥 닫아 TSV 가 안 남았다)

local MEM, VRAM, AC = emu.memType.pceMemory, emu.memType.pceVideoRam,
                      emu.memType.pceArcadeCardRam
local AC_ENGINE, AC_MAGIC = 0x1C0500, 0x1C04F0
local MAGIC = { 0x4B, 0x4F }
local PATH  = "C:/snatcher/SUBTITEL/0.2.13.bin"

local STUB, LIST = 0x5C20, 0x5C80       -- 엔진은 $5B80+0x98 까지.  안 겹친다
local HOOK, JSR_AT = 0x6072, 0x5C63
local SATB_BYTE = 0x2000                -- VDC 워드 $1000 -> VRAM 바이트 $2000

-- 스텁 ($5C20).  어셈블리는 위 주석의 형식 그대로.
local CODE = {
  0xA5,0x17,               -- 5C20  LDA $17            예산 남았나
  0x10,0x03,               -- 5C22  BPL $5C27
  0x4C,0xBE,0x43,          -- 5C24  JMP $43BE          없으면 그냥 나간다
  0xA9,0x3F,               -- 5C27  LDA #$3F
  0x38,                    -- 5C29  SEC
  0xE5,0x17,               -- 5C2A  SBC $17            A = 게임이 쓴 슬롯 수
  0x0A,0x0A,               -- 5C2C  ASL A / ASL A      *4 = SATB 워드 오프셋
  0xAA,                    -- 5C2E  TAX
  0x9C,0x00,0x00,          -- 5C2F  STZ $0000          VDC reg 0 = MAWR
  0x8E,0x02,0x00,          -- 5C32  STX $0002          MAWR 하위
  0xA9,0x10,               -- 5C35  LDA #$10
  0x8D,0x03,0x00,          -- 5C37  STA $0003          MAWR 상위 -> $1000+used*4
  0xA9,0x02,               -- 5C3A  LDA #$02
  0x8D,0x00,0x00,          -- 5C3C  STA $0000          VDC reg 2 = VWR
  0xA9,0xF4,               -- 5C3F  LDA #$F4
  0x85,0x08,               -- 5C41  STA $08            Y 원점 = 180+64
  0xA9,0x00,               -- 5C43  LDA #$00
  0x85,0x09,               -- 5C45  STA $09
  0xA9,0x84,               -- 5C47  LDA #$84
  0x85,0x0A,               -- 5C49  STA $0A            X 원점 = 100+32
  0xA9,0x00,               -- 5C4B  LDA #$00
  0x85,0x0B,               -- 5C4D  STA $0B
  0x64,0x0C,               -- 5C4F  STZ $0C            플립 없음
  0x64,0x0D,               -- 5C51  STZ $0D
  0x64,0x0E,               -- 5C53  STZ $0E            attr = 레코드 [4] & $8F
  0x64,0x0F,               -- 5C55  STZ $0F            팔레트 0
  0xA9,0x80,               -- 5C57  LDA #$80
  0x85,0x10,               -- 5C59  STA $10            리스트 = $5C80
  0xA9,0x5C,               -- 5C5B  LDA #$5C
  0x85,0x11,               -- 5C5D  STA $11
  0xA9,0x01,               -- 5C5F  LDA #$01
  0x85,0x16,               -- 5C61  STA $16            엔트리 1 개
  0x20,0x63,0x64,          -- 5C63  JSR $6463          ★ 게임 손을 빌린다
  0x4C,0xBE,0x43,          -- 5C66  JMP $43BE          원래 가던 곳
}
-- 레코드 1 개: 패턴 워드 $7900 -> SAT word2 $03C8 -> [3]=$C8, [4] bits6-4=011
local RECORD = { 0x00, 0x00, 0x00, 0xC8, 0xB0 }
local PATCH  = { 0x4C, STUB & 0xFF, STUB >> 8 }

local loaded, tries, frames = false, 0, 0
local installs, pushes, alive, dead = 0, 0, 0, 0
local slot_seen, logged = -1, 0
local lines = {}
local function say(s) emu.log(s); lines[#lines+1] = s end

local function flush()
  local name = string.format('C:/snatcher/dump/probe_sat_extend_0_1_0_%s.tsv',
                             os.date('%Y%m%d_%H%M%S'))
  local f = io.open(name, 'w')
  if f then
    f:write('line\n')
    for _, s in ipairs(lines) do f:write(s .. '\n') end
    f:close()
    emu.log('-> ' .. name)
  end
end

local fh = io.open(PATH, "rb")
if fh == nil then emu.log('★ 페이로드를 못 열었다: ' .. PATH) return end
local data = fh:read("a"); fh:close()
for i = 1, #MAGIC do emu.write(AC_MAGIC + i - 1, 0x00, AC) end

local function patched()
  for i = 1, #PATCH do
    if emu.read(HOOK + i - 1, MEM) ~= PATCH[i] then return false end
  end
  return true
end

local function install()
  for i = 1, #CODE   do emu.write(STUB + i - 1, CODE[i],   MEM) end
  for i = 1, #RECORD do emu.write(LIST + i - 1, RECORD[i], MEM) end
  for i = 1, #PATCH  do emu.write(HOOK + i - 1, PATCH[i],  MEM) end
  installs = installs + 1
  if installs <= 3 then
    say(string.format('[프레임 %d] 스텁 설치 %d 회째  $%04X -> JMP $%04X',
                      frames, installs, HOOK, STUB))
  end
end

emu.addEventCallback(function()
  frames = frames + 1

  if not loaded then
    tries = tries + 1
    for i = 1, #data do emu.write(AC_ENGINE + i - 1, data:byte(i), AC) end
    local bad = 0
    for i = 1, #data do
      if emu.read(AC_ENGINE + i - 1, AC) ~= data:byte(i) then bad = bad + 1 end
    end
    if bad == 0 then
      for i = 1, #MAGIC do emu.write(AC_MAGIC + i - 1, MAGIC[i], AC) end
      loaded = true
      say(string.format('AC 적재 완료 (%d 프레임째).  패턴이 VRAM $7900 에 올라간다', tries))
    elseif tries >= 300 then
      loaded = true; say('★ AC 적재 실패')
    end
  end

  -- 오버레이가 다시 로드되면 패치가 날아간다.  매 프레임 확인해서 되붙인다.
  if not patched() then install() end

  -- 지난 프레임에 민 엔트리가 프레임 끝까지 살아있나
  if slot_seen >= 0 then
    local base = SATB_BYTE + slot_seen * 8
    local ok = emu.read(base, VRAM) == 0xF4 and emu.read(base + 2, VRAM) == 0x84
                 and emu.read(base + 4, VRAM) == 0xC8
    if ok then alive = alive + 1 else dead = dead + 1 end
    if logged < 5 then
      logged = logged + 1
      local b = {}
      for i = 0, 7 do b[#b+1] = string.format('%02X', emu.read(base + i, VRAM) or 0) end
      say(string.format('[프레임 %d] 슬롯 %d  %s  %s',
                        frames, slot_seen, table.concat(b, ' '),
                        ok and '★ 생존' or '지워짐'))
    end
    slot_seen = -1
  end

  if frames % 300 == 0 then
    say(string.format('--- %d 프레임 --- 설치 %d · 푸시 %d · 생존 %d · 지워짐 %d',
                      frames, installs, pushes, alive, dead))
    flush()
  end
end, emu.eventType.startFrame)

-- 스텁이 게임 루프를 부르는 순간.  이때 $17 로 우리 슬롯 번호를 안다.
emu.addMemoryCallback(function()
  pushes = pushes + 1
  slot_seen = 0x3F - (emu.read(0x2017, MEM) or 0x3F)     -- zp $17 = CPU $2017
end, emu.callbackType.exec, JSR_AT, JSR_AT, emu.cpuType.pce, MEM)

emu.addEventCallback(function()
  say(string.format('--- 정리 --- %d 프레임 · 설치 %d · 푸시 %d · 생존 %d · 지워짐 %d',
                    frames, installs, pushes, alive, dead))
  if pushes == 0 then
    say('★ 스텁이 한 번도 안 불렸다 -- $6072 에 안 닿았거나 오버레이가 다르다')
  end
  flush()
end, emu.eventType.scriptEnded)

emu.log('PROBE_SAT_EXTEND 0.1.0 loaded')
emu.log('  음성 대사 장면으로.  글자가 뜨고 길리언 얼굴이 멀쩡하면 성공')
