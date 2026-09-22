-- SUB 0.5.187 -- 한 번의 UI 갱신에 AC 어느 주소를 다시 읽는가  ★순수 관측 · 쓰기 0 B
--
-- 무엇을 확정하려는가 -- 두 가지를 한 번에
-- ---------------------------------------------------------------------------
--   ① 글리프 루프가 아직 도는가 (아틀라스 잔재)
--   ② 커서 한 칸 이동에 레코드 몇 개를 다시 전개하는가
--
-- 0.5.186 의 PC 히스토그램으로는 ①을 판정할 수 없었다.  HuC6280 의 블록 전송
-- (TAI/TIA)은 옮기는 **모든 바이트가 같은 PC 로 찍힌다.**  그래서 "$BE34 x9" 가
-- "루프 9 회" 인지 "한 전송의 9 바이트 표본" 인지 구분이 안 된다.
-- 그 근거로 "AC 글리프 경로다" 라고 한 판정은 **취소한다.**
--
-- 대신 주소를 본다.  우리 헬퍼의 set_ac 가 이렇게 쓴다:
--
--     $1A02 = base low
--     $1A03 = base mid      <- 이 셋이 곧 읽으려는 AC 주소다
--     $1A04 = base high
--     $1A07 = 1 · $1A08 = 0 · $1A09 = $11     (제어 꼬리, 6 쓰기 한 세트)
--     ※ AC_FAST 판은 루프 안에서 base 3 개만 다시 쓴다 (set_ac_base)
--
-- AC 배치(빌더 docstring)로 영역을 가른다
--     $00000-$0FFFF  슬롯 디렉터리
--     $10000-$100FF  상태 페이지
--     $10100-$1035F  608 B 캐시 템플릿
--     $10360-$15FFF  전역 글리프 아틀라스     ★ 여기가 뜨면 글리프 루프가 산다
--     $16000-        레코드 팩                ★ 여기 주소 목록이 곧 재전개 목록
--   경계는 명목값이다.  raw 주소를 그대로 남기니 어긋나면 나중에 맞추면 된다.
--
-- 판정
--   ATLAS 세트 > 0                  -> ★ 아틀라스 잔재 확정.  스위치가 헬퍼에 안 걸렸다
--   ATLAS 세트 = 0                  -> BIOS 폰트 경로 맞다.  전부 텍스트 재전개다
--   갱신 한 번에 PACK 고유주소 13 개 -> ★ 메뉴 전체 재그리기 확정 (문서의 "13 records")
--   갱신 한 번에 1~2 개             -> 이미 부분 갱신 중.  범인은 다른 데
--
-- 쓰는 법
--   1) 이것만 로드.  정상 속도
--   2) 메뉴 띄우고 **가만히 3 초**       -> 바닥값 확인
--   3) 커서를 한 칸만 움직인다           -> 그 프레임의 PACK 고유주소를 센다
--   4) 한 칸씩 서너 번 더                -> 매번 같은 목록이 나오는지
--   R = 구간 표식
--
-- 산출물
--   _frames.tsv   프레임마다 영역별 세트 수 · 읽기 수 · PACK 고유주소 개수
--   _addrs.tsv    큰 프레임의 AC 주소를 **순서대로** 전부 (이게 육안 증거다)
--   _summary.txt  끝날 때 요약

local BIG        = 200    -- 읽기가 이만큼 넘는 프레임을 "갱신" 으로 보고 주소를 다 남긴다
local MAX_ADDR   = 400    -- 한 프레임에 남길 주소 상한
local MAX_BIGF   = 40     -- 주소를 다 남길 프레임 수 상한 (파일 폭발 방지)
local REPORT     = 120

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local BASE  = 'C:/snatcher/dump/acrec_0_5_187_' .. STAMP

local fout = assert(io.open(BASE .. '_frames.tsv', 'w'))
fout:write('frame\tmark\trd\tsets\tdir\tstate\ttpl\tatlas\tpack\tpack_uniq\tfirst_pack\tlast_pack\n')
fout:flush()

local aout = assert(io.open(BASE .. '_addrs.tsv', 'w'))
aout:write('frame\tseq\taddr\tregion\n')
aout:flush()

local function say(m) emu.log(m); print(m) end

local function region(a)
  if a < 0x10000 then return 'DIR' end
  if a < 0x10100 then return 'STATE' end
  if a < 0x10360 then return 'TPL' end
  if a < 0x16000 then return 'ATLAS' end
  return 'PACK'
end

-- set_ac 조립
local lo, mid, hi = 0, 0, 0
local seq, addrs = 0, {}
local rdCount = 0

emu.addMemoryCallback(function(address, value)
  value = (value or 0) & 0xFF
  local off = address & 0xFF
  if off == 0x02 then lo = value
  elseif off == 0x03 then mid = value
  elseif off == 0x04 then
    hi = value
    -- lo/mid/hi 가 이 순서로 쓰이므로 $1A04 가 주소 한 벌의 완성점이다
    if #addrs < MAX_ADDR then
      seq = seq + 1
      addrs[#addrs + 1] = lo | (mid << 8) | (hi << 16)
    end
  end
end, emu.callbackType.write, 0x1A00, 0x1AFF, CPU, MEM)

emu.addMemoryCallback(function()
  rdCount = rdCount + 1
end, emu.callbackType.read, 0x1A00, 0x1AFF, CPU, MEM)

-- R 키
local KEY = nil
for _, n in ipairs({ 'R', 'r', 'KeyR' }) do
  local ok, v = pcall(function() return emu.isKeyPressed(n) end)
  if ok and type(v) == 'boolean' then KEY = n break end
end
local held, marks = false, 0

local frame, bigFrames = 0, 0
local gRegion = { DIR=0, STATE=0, TPL=0, ATLAS=0, PACK=0 }
local gPackUniq, gMaxUniq, gMaxFrame = {}, 0, 0

emu.addEventCallback(function()
  frame = frame + 1

  local down = false
  if KEY then down = (emu.isKeyPressed(KEY) == true) end
  local mark = (down and not held) and 1 or 0
  held = down
  if mark == 1 then marks = marks + 1; say(('  ── 표식 #%d  f%d'):format(marks, frame)) end

  local n = #addrs
  if n > 0 or rdCount > 0 or mark == 1 then
    local cnt = { DIR=0, STATE=0, TPL=0, ATLAS=0, PACK=0 }
    local uniq, uniqN, firstP, lastP = {}, 0, -1, -1
    for _, a in ipairs(addrs) do
      local r = region(a)
      cnt[r] = cnt[r] + 1
      gRegion[r] = gRegion[r] + 1
      if r == 'PACK' then
        if uniq[a] == nil then uniq[a] = true; uniqN = uniqN + 1 end
        gPackUniq[a] = (gPackUniq[a] or 0) + 1
        if firstP < 0 then firstP = a end
        lastP = a
      end
    end
    if uniqN > gMaxUniq then gMaxUniq, gMaxFrame = uniqN, frame end

    fout:write(('%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%06X\t%06X\n'):format(
      frame, mark, rdCount, n, cnt.DIR, cnt.STATE, cnt.TPL, cnt.ATLAS, cnt.PACK,
      uniqN, (firstP < 0) and 0 or firstP, (lastP < 0) and 0 or lastP))
    fout:flush()

    -- 큰 프레임은 주소를 순서대로 통째로 남긴다
    if rdCount >= BIG and bigFrames < MAX_BIGF then
      bigFrames = bigFrames + 1
      for i, a in ipairs(addrs) do
        aout:write(('%d\t%d\t%06X\t%s\n'):format(frame, i, a, region(a)))
      end
      aout:flush()
      say(('★ f%d  읽기 %d · set %d · PACK 고유 %d · ATLAS %d')
          :format(frame, rdCount, n, uniqN, cnt.ATLAS))
    end
  end

  addrs, rdCount = {}, 0

  if frame % REPORT == 0 then
    say(('f%d  DIR %d · STATE %d · TPL %d · ATLAS %d · PACK %d  (최대 PACK고유 %d @f%d)')
        :format(frame, gRegion.DIR, gRegion.STATE, gRegion.TPL,
                gRegion.ATLAS, gRegion.PACK, gMaxUniq, gMaxFrame))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  fout:close(); aout:close()
  local s = assert(io.open(BASE .. '_summary.txt', 'w'))
  local function put(m) s:write(m .. '\n'); say(m) end
  put(('프레임 %d · 표식 %d'):format(frame, marks))
  put(('영역별 set_ac  DIR %d · STATE %d · TPL %d · ATLAS %d · PACK %d')
      :format(gRegion.DIR, gRegion.STATE, gRegion.TPL, gRegion.ATLAS, gRegion.PACK))
  if gRegion.ATLAS > 0 then
    put('★ ATLAS 접근이 있다 -> 글리프 루프가 살아 있다 (아틀라스 잔재 확정)')
  else
    put('ATLAS 접근 0 -> BIOS 폰트 경로 맞다.  양은 전부 텍스트 재전개에서 나온다')
  end
  put(('한 프레임 최대 PACK 고유주소 %d 개 (f%d)'):format(gMaxUniq, gMaxFrame))
  local rows = {}
  for a, c in pairs(gPackUniq) do rows[#rows+1] = { a = a, c = c } end
  table.sort(rows, function(x, y) return x.c > y.c end)
  put(('서로 다른 PACK 주소 %d 개.  많이 읽힌 순 상위:'):format(#rows))
  for i = 1, math.min(#rows, 20) do
    put(('   $%06X  %d 회'):format(rows[i].a, rows[i].c))
  end
  s:close()
  say('  ' .. BASE .. '_summary.txt')
end, emu.eventType.scriptEnded)

say('SUB 0.5.187-ac-record-trace armed -- AC 주소 복원 · 쓰기 0 B')
say('  1) 메뉴 띄우고 가만히 3 초   2) 커서 한 칸   3) 서너 번 더')
if KEY then say(('  %s = 구간 표식'):format(KEY)) end
say('  ' .. BASE .. '_frames.tsv / _addrs.tsv')
