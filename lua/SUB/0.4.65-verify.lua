-- SUB 0.4.65-verify -- 0.4.64 위에 얹는 **읽기 전용** 침범 감시
--
-- ── 무엇을 가리려고 만들었나 ──────────────────────────────────────────────
--
-- 증상: 한 장면에서 앞 대사 서너 개는 완벽한데 그 뒤부터 자막이 깨진다.
--       base 는 그 사이 바뀌지 않는다 (KEY #1~#5 가 전부 $3B80 이었다).
--
-- 같은 주소인데 앞은 되고 뒤는 안 된다면 자리 선택 문제가 아니다.  둘 중 하나다.
--
--     A  우리가 처음부터 잘못 쓴다        -> 업로드 직후 이미 팩과 다르다
--     B  쓴 뒤에 게임이 덮는다             -> 처음엔 맞다가 N 프레임 뒤 달라진다
--
-- 이 파일은 그 둘을 가른다.  **아무것도 쓰지 않는다.**  0.4.64 가 자리를 박은 뒤
-- 블록을 지문으로 떠 두고, 매 프레임 대조해서 처음 달라지는 순간을 잡는다.
--
-- ── 읽는 법 ──────────────────────────────────────────────────────────────
--
--     VERIFY $3B80 키 00680E2A1321  +47f 침범  word $3C40 (블록+192)
--       -> B.  47 프레임 뒤에 게임이 가져갔다.  그 자리를 언제 쓰는지가 답이다
--
--     VERIFY $3B80 키 00200EB36939  캡처 시점에 이미 팩과 불일치
--       -> A.  업로드 경로 문제다.  자리를 아무리 잘 골라도 안 낫는다
--
-- 침범이면 블록 안 **어느 위치**가 먼저 깨지는지도 같이 찍는다.  앞쪽이면
-- 우리 블록 시작 직전에 뭔가가 걸쳐 있다는 뜻이고, 뒤쪽이면 그 반대다.
--
-- ── 쓰는 법 ──────────────────────────────────────────────────────────────
--
--     이 파일 하나만 로드한다 (안에서 0.4.64 를 부른다)
--     dump/verify_0_4_65_<시각>.tsv 에 표로도 남는다

dofile('C:/snatcher/lua/SUB/0.4.64-fixedbase.lua')

local MEM  = emu.memType.pceMemory
local VRAM = emu.memType.pceVideoRam
local CPU  = emu.cpuType.pce

local ENGINE   = 0x5B80
local COUNT_OK = ENGINE + 118
local SELECTOR = ENGINE + 345
local VRAM_LO, VRAM_HI = 144, 146

local NEED = 19 * 0x40            -- 1216 word
local SAMPLES = 64                -- 블록을 64 지점으로 요약한다
local STEP = NEED // SAMPLES
local CAPTURE_DELAY = 3           -- 글리프 업로드가 끝난 뒤에 지문을 뜬다

local stamp = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/verify_0_4_65_' .. stamp .. '.tsv'
local out = io.open(OUT, 'w')
if out then
  out:write('key\tbase\tverdict\tframes\tword\toffset\twas\tnow\n')
  out:flush()
end

local function rw(w)
  local at = w * 2
  return (emu.read(at, VRAM) or 0) | ((emu.read(at + 1, VRAM) or 0) << 8)
end

local function keyHex()
  local t = {}
  for i = 0, 5 do
    t[i + 1] = string.format('%02X', emu.read(SELECTOR + i, MEM) or 0)
  end
  return table.concat(t)
end

local function fingerprint(base)
  local t = {}
  for i = 0, SAMPLES - 1 do t[i + 1] = rw(base + i * STEP) end
  return t
end

-- 현재 감시 대상
local base, key = nil, nil
local wait, fp, age = 0, nil, 0
local placed, clean, invaded, badUpload = 0, 0, 0, 0
local reported = false

local function record(verdict, frames, word, offset, was, now)
  if out then
    out:write(string.format('%s\t%04X\t%s\t%d\t%s\t%s\t%s\t%s\n',
      key or '-', base or 0, verdict, frames,
      word and string.format('%04X', word) or '-',
      offset and tostring(offset) or '-',
      was and string.format('%04X', was) or '-',
      now and string.format('%04X', now) or '-'))
    out:flush()
  end
end

-- 0.4.64 가 피연산자를 고친 **뒤**에 읽어야 하므로 같은 주소에 나중에 등록한다.
emu.addMemoryCallback(function()
  base = (emu.read(ENGINE + VRAM_LO, MEM) or 0) |
         ((emu.read(ENGINE + VRAM_HI, MEM) or 0) << 8)
  key = keyHex()
  wait, fp, age, reported = CAPTURE_DELAY, nil, 0, false
  placed = placed + 1
end, emu.callbackType.exec, COUNT_OK, COUNT_OK, CPU, MEM)

emu.addEventCallback(function()
  if base then
    if wait > 0 then
      wait = wait - 1
      if wait == 0 then
        fp = fingerprint(base)
        -- 팩과의 대조는 못 한다 (글리프 원본을 여기서 안 읽는다).  대신
        -- "전부 0" 이면 업로드가 아예 안 된 것이므로 그것만 잡아낸다.
        local nz = 0
        for i = 1, SAMPLES do if fp[i] ~= 0 then nz = nz + 1 end end
        if nz == 0 then
          badUpload = badUpload + 1
          reported = true
          emu.log(string.format('SUB 0.4.65 VERIFY $%04X 키 %s · 캡처 시점에 블록이 전부 0 -- 업로드가 안 됐다',
                                base, key))
          record('업로드없음', CAPTURE_DELAY)
        end
      end
    elseif fp and not reported then
      age = age + 1
      for i = 1, SAMPLES do
        local w = base + (i - 1) * STEP
        local now = rw(w)
        if now ~= fp[i] then
          invaded = invaded + 1
          reported = true
          emu.log(string.format(
            'SUB 0.4.65 VERIFY $%04X 키 %s · +%df 침범  word $%04X (블록+%d)  %04X -> %04X',
            base, key, age, w, w - base, fp[i], now))
          record('침범', age, w, w - base, fp[i], now)
          break
        end
      end
      if not reported and age == 90 then
        clean = clean + 1
        reported = true
        record('정상', age)
      end
    end
  end

  emu.drawString(4, 64, string.format('0.4.65 배치 %d  정상 %d  침범 %d  미업로드 %d',
                 placed, clean, invaded, badUpload),
                 invaded > 0 and 0xFF6060 or 0x60FF60, 0x000000)
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if out then out:close(); out = nil end
  emu.log(string.format('SUB 0.4.65 VERIFY 끝 -- 배치 %d · 정상 %d · 침범 %d · 미업로드 %d',
                        placed, clean, invaded, badUpload))
  emu.log('  ' .. OUT)
end, emu.eventType.scriptEnded)

emu.log('SUB 0.4.65-verify armed -- 읽기 전용 침범 감시 (쓰기 0)')
emu.log(string.format('  배치 %d프레임 뒤 지문 %d점 · 90프레임까지 대조', CAPTURE_DELAY, SAMPLES))
emu.log('  침범이면 "몇 프레임 뒤 · 블록의 어느 위치" 가 찍힌다')
emu.log('  ' .. OUT)
