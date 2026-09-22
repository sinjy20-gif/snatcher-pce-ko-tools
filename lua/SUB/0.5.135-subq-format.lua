-- SUB 0.5.135 -- CD_SUBQ 결과 $20A0 의 형식을 본다 (쓰기 0 B)
--
-- 왜 이걸 재나
-- ---------------------------------------------------------------------------
-- 0.5.134 로 확인된 것:
--
--     cdrom.audioPlayer.currentSector 가 재생 중 증가한다 (에뮬 상태)
--     startSector / endSector 로 현재 트랙 경계도 나온다
--
-- 그런데 그건 **에뮬레이터 상태**이지 6280 코드가 읽을 수 있다는 뜻이 아니다.
-- 우리 네이티브가 읽을 경로가 따로 있어야 하는데, 게임 안에 이미 있다:
--
--     $6111  LDA #$A0 / STA $FA / LDA #$20 / STA $FB
--            JSR $E01E              ★ CD_SUBQ (BIOS)
--            CMP #0 / BNE 재시도
--            LDA $20A0 / CMP #2 / BNE 재시도
--     $6230  per-frame CD_STAT poll (opening probe 관측)
--
-- 즉 **게임이 이미 위치를 $20A0 에 받아온다.**  우리는 읽기만 하면 된다.
--
-- ★ 남은 것은 형식뿐이다.
--   CD_SUBQ 는 보통 BCD MSF(분:초:프레임)를 준다.  색인은 LBA 다.
--   비교하려면 변환이 필요하고, 그 변환이 6280 에서 몇 바이트냐가 이번 작업의 비용이다.
--
--     MSF -> LBA :  (분×60 + 초) × 75 + 프레임 - 150
--
-- 무엇을 재나
-- ---------------------------------------------------------------------------
--     $20A0..$20AF 16 B 를 프레임마다 읽어, 값이 바뀌면 찍는다
--     같이 에뮬의 audioPlayer.currentSector 를 옆에 놓는다
--     -> 두 값을 나란히 보면 형식이 바로 갈린다
--
-- 읽는 법
-- ---------------------------------------------------------------------------
--     $20A1..$20A3 이 BCD 로 분·초·프레임처럼 흐른다
--         -> MSF.  변환식이 필요하다.  (예: 47:05:20 이면 47 05 20 이 BCD 로 보인다)
--            초가 59(BCD 0x59)에서 0 으로 넘어가는 것을 확인하면 확정이다
--     어떤 3 바이트가 currentSector 와 **선형으로** 같이 움직인다
--         -> 이미 LBA 다.  변환이 필요 없다 -- 최상
--     $20A0 이 2 로 고정
--         -> 게임 코드가 그것을 상태값으로 본다 ($6111 의 CMP #2).  위치는 그 뒤다
--
-- ⚠ 형식을 눈으로 못 가르면, currentSector 와의 상관을 로그에서 계산할 것.
--   MSF 면 초 자리가 75 프레임마다 1 씩 오른다.
--
-- ★ 화면에 아무것도 안 그린다.  게임을 한 바이트도 안 고친다.
--
--   BIOS  build/patch/0.4.6.68/Syscard3_galmuri_0.4.6.68.pce
--   CUE   같은 폴더 [KO].cue
--   Power Cycle -> 이 파일만 로드 -> 오프닝 CD-DA 를 재생
--
-- 산출물  C:/snatcher/dump/subq_0_5_135_<시각>.tsv

local MEM = emu.memType.pceMemory

local SUBQ = 0x20A0
local N = 16

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/subq_0_5_135_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tcurrentSector\tstartSector\tendSector\t')
for i = 0, N - 1 do out:write(string.format('%04X\t', SUBQ + i)) end
out:write('추정\n')

local function say(f, ...) emu.log(string.format(f, ...)) end
local function rd(a)
  local ok, v = pcall(emu.read, a, MEM)
  return (ok and type(v) == 'number') and v or -1
end

local function stnum(s, k)
  local v = s and s[k]
  return type(v) == 'number' and math.floor(v) or -1
end

-- BCD 로 그럴듯한가 (각 니블이 0~9, 그리고 분/초 범위)
local function bcd(b)
  local hi, lo = b >> 4, b & 0x0F
  if hi > 9 or lo > 9 then return nil end
  return hi * 10 + lo
end

local frame, lastKey, rows = 0, nil, 0

emu.addEventCallback(function()
  frame = frame + 1
  local ok, s = pcall(emu.getState)
  local cur = ok and stnum(s, 'cdrom.audioPlayer.currentSector') or -1
  local st  = ok and stnum(s, 'cdrom.audioPlayer.startSector') or -1
  local en  = ok and stnum(s, 'cdrom.audioPlayer.endSector') or -1

  local b = {}
  for i = 0, N - 1 do b[i] = rd(SUBQ + i) end
  local key = table.concat(b, ',', 0, N - 1)
  if key == lastKey then return end
  lastKey = key
  rows = rows + 1

  -- MSF 후보 찾기: 연속 3 바이트가 전부 BCD 이고 초<60 · 프레임<75
  local guess = ''
  for i = 0, N - 4 do
    local m, sc, fr = bcd(b[i]), bcd(b[i+1]), bcd(b[i+2])
    if m and sc and fr and sc < 60 and fr < 75 then
      local lba = (m * 60 + sc) * 75 + fr - 150
      guess = guess .. string.format('%04X=MSF %02d:%02d:%02d(LBA %d) ',
                                     SUBQ + i, m, sc, fr, lba)
    end
  end
  -- LBA 후보: 연속 3 바이트를 LE/BE 로 읽어 currentSector 와 가까운가
  for i = 0, N - 3 do
    local le = b[i] | (b[i+1] << 8) | (b[i+2] << 16)
    local be = (b[i] << 16) | (b[i+1] << 8) | b[i+2]
    if cur > 0 then
      if math.abs(le - cur) <= 300 then
        guess = guess .. string.format('%04X=LBA_LE %d ', SUBQ + i, le) end
      if math.abs(be - cur) <= 300 then
        guess = guess .. string.format('%04X=LBA_BE %d ', SUBQ + i, be) end
    end
  end

  local line = { tostring(frame), tostring(cur), tostring(st), tostring(en) }
  for i = 0, N - 1 do line[#line + 1] = string.format('%02X', b[i]) end
  line[#line + 1] = guess
  out:write(table.concat(line, '\t') .. '\n'); out:flush()

  if rows <= 40 or rows % 200 == 0 then
    local hex = {}
    for i = 0, N - 1 do hex[#hex + 1] = string.format('%02X', b[i]) end
    say('f%-6d cur=%-7d [%s]', frame, cur, table.concat(hex, ' '))
    if guess ~= '' then say('        -> %s', guess) end
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:close()
  say('0.5.135 끝 -- 변화 %d 회 · 저장 %s', rows, PATH)
  if rows == 0 then
    say('0.5.135 ⚠ $20A0 이 한 번도 안 변했다.  CD_SUBQ 가 안 불렸거나 자리가 다르다.')
    say('0.5.135   "위치를 못 읽는다" 가 아니라 "이 자리에서는 못 봤다" 다')
  end
end, emu.eventType.scriptEnded)

say('SUB 0.5.135-subq-format armed -- 순수 관측 · 게임 무수정 · 화면 무개입')
say('  묻는 것 : 게임이 CD_SUBQ 로 받아오는 $20A0 의 형식이 MSF 인가 LBA 인가')
say('  $20A0..$20AF 16 B 를 에뮬의 currentSector 옆에 놓고 본다')
say('  덤프 : ' .. PATH)
