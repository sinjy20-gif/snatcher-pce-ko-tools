-- PROBE GFX 0.1.4 -- 글자 타일이 **어떤 순서로** 올라오는지 잰다
--
-- ★ 순수 관측.  아무것도 안 쓴다.  화면에도 아무것도 안 그린다.
--
-- 왜
-- --
-- Lua 주입판(0.2.2 / 0.3.0)은 "글자 타일 구간 4 KB 를 매 프레임 훑어 안 바뀌면
-- 넣는다" 로 업로드 종료를 판정한다.  Lua 는 공짜지만 **네이티브는 아니다.**
-- VRAM 은 VDC 포트로만 읽히고 워드당 10 사이클쯤 든다:
--
--     2,000 워드 x 10 사이클 = 20,000 사이클/프레임
--     PCE 한 프레임 = 약 119,000 사이클    -> ★프레임의 17 %
--
-- CD-DA 자막 드리프트가 바로 "프레임 예산 초과" 에서 나왔다 (§21-3).  여기서
-- 17 % 를 더 쓰면 같은 문제를 부른다.
--
-- 그래서 **가장 나중에 채워지는 타일 하나**만 보면 된다.  그게 채워졌다는 건
-- 업로드가 끝났다는 뜻이고, 8 바이트만 읽으면 되니 비용이 사실상 0 이다.
-- 이 프로브가 그 타일을 찾는다.
--
-- 무엇을 남기나
-- -------------
--     타일마다  처음 채워진 프레임 · 마지막으로 바뀐 프레임 · 바뀐 횟수
--     ★마지막에 채워진 타일         <- 네이티브의 안정 판정에 쓴다
--     지문 타일($16A)이 채워진 시점 <- 지문 등장 ~ 완료 사이의 창
--
-- ⚠ 헌사 화면 **직전**에 올릴 것.  업로드를 처음부터 봐야 순서가 나온다.
-- ⚠ 한 번 재고 끝내지 말 것.  순서가 매번 같은지 두 번은 봐야 한다
--   (게임이 장면에 따라 다른 경로로 올릴 수 있다).
--
-- 산출물  C:/snatcher/dump/upload_order_<시각>.tsv

local VRAM = emu.memType.pceVideoRam

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/upload_order_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('tile\tfirst_filled\tlast_changed\tchanges\n')

local function say(m) emu.log(m); print(m) end

local TILE_FIRST, TILE_LAST = 0x111, 0x18C
local SIG_TILE = 0x16A
local PROBE_BYTES = 4          -- 타일마다 앞 4 B 만 본다 (124 x 4 = 496 읽기/프레임)

local frame = 0
local prev, first_filled, last_changed, changes = {}, {}, {}, {}
local filled_count, last_report = 0, -1
local started, quiet = nil, 0

local function sample(t)
  local base = t * 32
  local a = emu.read(base, VRAM) or 0
  local b = emu.read(base + 1, VRAM) or 0
  local c = emu.read(base + 2, VRAM) or 0
  local d = emu.read(base + 3, VRAM) or 0
  return a * 0x1000000 + b * 0x10000 + c * 0x100 + d
end

emu.addEventCallback(function()
  frame = frame + 1
  local moved = 0
  local nfilled = 0
  for t = TILE_FIRST, TILE_LAST do
    local v = sample(t)
    if v ~= 0 then nfilled = nfilled + 1 end
    if prev[t] ~= nil and v ~= prev[t] then
      moved = moved + 1
      changes[t] = (changes[t] or 0) + 1
      last_changed[t] = frame
      if first_filled[t] == nil and v ~= 0 then first_filled[t] = frame end
    elseif prev[t] == nil and v ~= 0 then
      first_filled[t] = frame
      last_changed[t] = frame
      changes[t] = 1
    end
    prev[t] = v
  end

  if moved > 0 then
    if started == nil then
      started = frame
      say(('★업로드 시작  f%d'):format(frame))
    end
    quiet = 0
    if nfilled ~= last_report then
      say(('  f%-7d 채워진 타일 %3d / %d   (이번 프레임에 바뀐 것 %d)')
        :format(frame, nfilled, TILE_LAST - TILE_FIRST + 1, moved))
      last_report = nfilled
    end
  elseif started ~= nil then
    quiet = quiet + 1
    if quiet == 60 then
      say(('★60 프레임 무변화  f%d  -- 업로드가 끝났다'):format(frame))
      -- 마지막에 바뀐 타일을 찾는다
      local best, at = nil, -1
      for t = TILE_FIRST, TILE_LAST do
        if (last_changed[t] or -1) > at then best, at = t, last_changed[t] end
      end
      say('')
      say(('  업로드 f%d ~ f%d   (%d 프레임)'):format(started, at, at - started + 1))
      say(('  ★마지막에 바뀐 타일  $%03X  (f%d)'):format(best, at))
      say(('    -> 네이티브는 이 타일만 보면 된다 (VRAM $%04X, 8 B)'):format(best * 32))
      say(('  지문 타일 $%03X 는 f%s 에 채워졌다  -> 지문 등장 ~ 완료 %s 프레임')
        :format(SIG_TILE, tostring(first_filled[SIG_TILE] or -1),
                tostring(at - (first_filled[SIG_TILE] or at))))
      -- 늦게 채워진 것 10 개
      local order = {}
      for t = TILE_FIRST, TILE_LAST do
        if last_changed[t] then order[#order + 1] = t end
      end
      table.sort(order, function(x, y) return last_changed[x] > last_changed[y] end)
      say('')
      say('  늦게 바뀐 순서 (뒤에서 10 개)')
      for i = 1, math.min(10, #order) do
        local t = order[i]
        say(('    $%03X  f%-7d  바뀜 %d 회'):format(t, last_changed[t], changes[t] or 0))
      end
    end
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  for t = TILE_FIRST, TILE_LAST do
    out:write(('%03X\t%s\t%s\t%d\n'):format(
      t, tostring(first_filled[t] or ''), tostring(last_changed[t] or ''),
      changes[t] or 0))
  end
  out:write('#\n')
  out:write(('# 전체 %d 프레임 · 업로드 시작 f%s\n')
    :format(frame, tostring(started or 0)))
  out:close()
  say('')
  say('  ' .. PATH)
end, emu.eventType.scriptEnded)

say('PROBE GFX 0.1.4-upload-order armed -- 순수 관측')
say('  헌사 화면 **직전**에 올릴 것.  업로드가 끝나면 자동으로 결과를 찍는다')
say('  ' .. PATH)
