-- PROBE_SUB_SATB 0.1.0 -- 자막이 왜 둘로 보이나 (2026-08-26)
--
-- 증상
-- ----
-- 자막이 SAT 가 겹쳐 **두 개로** 나온다.  그리고 뜰 때 프레임이 버벅인다.
--
-- 구조
-- ----
-- 엔진은 VDC 를 직접 안 건드린다.  게임의 푸시 루프 `$6463` 에 우리 레코드를
-- 물려서 밀어 넣는다.
--
--     push:  y = record.y + 64 · x = 160
--            $10/$11 <- list 포인터 · $16 <- 글자 수
--            $17 <- 0x3F      ★ 남은 슬롯 예산
--            JSR $6463
--
-- 게임은 `$60A6` 에서 **남은 슬롯을 0 으로 채운다.**  우리 푸시가 `$17` 을 깎으니
-- 그 0 채우기가 우리 뒤부터 맞아떨어진다는 설계다.
--
-- 어긋나면 앞 프레임에 쓴 스프라이트가 안 지워지고, 이번 프레임 것과 겹쳐
-- **둘로 보인다.**  매 프레임 다시 미느라 무겁기도 하다.  증상 둘이 한 뿌리일 수
-- 있다 -- 그러나 아직 짐작이다.
--
-- 그래서 SATB 를 직접 뜬다
-- ------------------------
-- VRAM `$1000-$10FF` = 스프라이트 64 개 x 4 워드 (y · x · 패턴 · 속성).
-- 자막이 뜬 동안 매 프레임 훑어서:
--
--     우리 것이 몇 개인가        패턴이 글리프 자리($7900 계열)를 가리키는 것
--     어느 슬롯에 있나           둘로 보이면 슬롯 두 벌이 잡힐 것이다
--     y/x 가 같은가 다른가       같으면 겹침, 다르면 잔상
--     $17 은 얼마로 남았나       0 채우기가 어디부터 도는지
--
-- 쓰는 법
-- -------
--   1) Mesen 에 올린다
--   2) 접수처 첫 대사에서 자막이 뜨는 것을 본다
--   3) Stop  ->  dump/sub_satb_0_1_0_<시각>.tsv

local MEM  = emu.memType.pceMemory
local VRAM = emu.memType.pceVideoRam

local SATB = 0x1000           -- VRAM 워드
local SPRITES = 64
local GLYPH_VRAM = 0x7900     -- 글리프를 올리는 자리 (엔진 기본값)

local stamp = os.date("%Y%m%d_%H%M%S")
local PATH = "C:\\snatcher\\dump\\sub_satb_0_1_0_" .. stamp .. ".tsv"

local rows = {}
local frames, samples = 0, 0
local was_playing = false
local active = false

-- 패턴 워드가 글리프 자리를 가리키나.  $6463 이 쓰는 형식은
--   패턴 = (VRAM워드 >> 6) << 1  이므로 되돌려서 본다.
local function is_ours(pattern)
  local word = (pattern >> 1) << 6
  return word >= GLYPH_VRAM and word < GLYPH_VRAM + 0x600
end

emu.addEventCallback(function()
  frames = frames + 1
  local ok, s = pcall(emu.getState)
  if not ok or not s then return end

  local playing = s["cdrom.adpcm.playing"] == true
  if playing and not was_playing then active = true end
  if not playing and was_playing then
    -- 재생이 끝난 뒤로도 몇 프레임 더 본다 -- 잔상이 남는지 보려는 것
    active = frames + 90
  end
  was_playing = playing
  if active == false then return end
  if type(active) == "number" and frames > active then active = false; return end

  -- SATB 를 훑는다
  local ours, slots, first_y, first_x = 0, {}, -1, -1
  local groups = {}
  for i = 0, SPRITES - 1 do
    local at = SATB + i * 4
    local y = emu.read(at, VRAM) or 0
    local x = emu.read(at + 1, VRAM) or 0
    local pattern = emu.read(at + 2, VRAM) or 0
    if pattern ~= 0 and is_ours(pattern) then
      ours = ours + 1
      slots[#slots + 1] = i
      local key = string.format("y%d,x%d", y, x)
      groups[key] = (groups[key] or 0) + 1
      if first_y < 0 then first_y, first_x = y, x end
    end
  end

  if ours > 0 then
    samples = samples + 1
    -- 같은 y/x 무리가 몇 벌인가 = 둘로 보이는 원인
    local list = {}
    for key, n in pairs(groups) do list[#list + 1] = key .. "=" .. n end
    table.sort(list)
    rows[#rows + 1] = table.concat({
      frames, ours, tostring(slots[1]), tostring(slots[#slots]),
      first_y, first_x,
      table.concat(list, " "),
      string.format("%02X", emu.read(0x17, MEM) or 0),
      string.format("%02X", emu.read(0x16, MEM) or 0),
      playing and "play" or "after",
    }, "\t")
    if samples <= 6 or samples % 30 == 0 then
      emu.log(string.format("[프레임 %d] 우리 스프라이트 %d 개 · 슬롯 %d..%d · 무리 %s · $17=%02X",
                            frames, ours, slots[1], slots[#slots],
                            table.concat(list, " "), emu.read(0x17, MEM) or 0))
    end
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  local file = io.open(PATH, "w")
  if file == nil then return end
  file:write("frame\tours\tslot_first\tslot_last\ty\tx\tgroups\tzp17\tzp16\tphase\n")
  file:write(table.concat(rows, "\n") .. "\n")
  file:close()
  emu.log(string.format("SATB -- 표본 %d 프레임 -> %s", samples, PATH))
  emu.log("  무리(groups)가 두 벌이면 겹침이다.  한 벌인데 개수가 두 배면 같은 자리 중복이다")
end, emu.eventType.scriptEnded)

emu.log("PROBE_SUB_SATB 0.1.0 -- 자막이 뜨는 동안 SATB 를 훑는다")
emu.log("  접수처 첫 대사까지 간 뒤 Stop.  -> " .. PATH)
