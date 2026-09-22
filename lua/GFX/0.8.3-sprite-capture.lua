-- GFX 0.8.3 -- 장면마다 + **F 를 누른 그 순간**에도 VRAM 을 뜬다
--
-- 0.8.2 가 빠뜨린 것
-- ------------------
-- 0.8.2 는 장면 전환에서만 VRAM 을 떴다.  그런데 소유자가 보려는 화면은 **F 를 누른
-- 그 순간**이다.  자막이 천천히 뜨거나 한 글자씩 나타나면 전환 문턱(CHANGE)에 안
-- 걸려서 그 장면 스냅샷이 아예 없다 -- 2026-09-16 에 「<원문 8자>」가 그랬다.
-- 이제 F 를 누르면 그 프레임의 VRAM/CRAM 을 반드시 남긴다.
--
-- 0.8.0 이 틀렸던 것
-- ------------------
-- 0.8.0 은 스프라이트 **목록**은 구간 내내 모으는데 **VRAM 은 마지막 한 순간**만
-- 저장했다.  그래서 오프닝을 통째로 돌리면 목록에는 모스크바 자막(프레임 8610)이
-- 들어 있는데, 그 패턴 자리를 읽어 보면 프레임 16500 시점의 **다른 그림**이 나온다
-- (2026-09-16 실측: `$5000`대가 자막이 아니라 도시 풍경이었다).
--
--   ★ 목록을 누적하게 고치면서 VRAM 쪽을 같이 안 고친 것이 원인이다.
--
-- 이 판이 하는 것
-- ---------------
-- 살아 있는 스프라이트 집합이 **크게 바뀌면 장면이 바뀐 것**으로 보고, 그 자리에서
-- VRAM 64 KB + CRAM 을 **프레임 번호가 붙은 파일**로 남긴다.  주행 한 번으로
-- 모든 장면의 그림을 건진다 (소유자 주행 한 번이 15~20 분이라 두 번 돌릴 수 없다).
--
-- 쓰는 법
-- -------
--   LABEL 을 주행 이름으로 바꾸고 **오프닝 시작 전에** 올린다.  끝까지 본 뒤 F.
--   (장면마다 따로 돌릴 필요 없다 -- 한 번에 다 담긴다)
--
-- 산출물  C:/snatcher/dump/sprite_<LABEL>_<시각>_*
--           _sprites.tsv          구간 내내 살아 있던 스프라이트 전부
--                                 (first_frame 으로 아래 스냅샷과 짝을 맞춘다)
--           _sprites_last.tsv     마지막 프레임의 화면 그대로
--           _scenes.tsv           ★ 장면 목록: frame · 스프라이트수 · 스냅샷 파일
--           _vram_f<프레임>.bin    ★ 장면마다 VRAM 64 KB
--           _cram_f<프레임>.bin    ★ 장면마다 CRAM (색 없는 미리보기는 거짓말이다)
--
-- Mesen: Script -> Settings -> Restrictions -> Allow I/O and OS 를 켤 것.
-- 게임 RAM/VRAM/CRAM 에 한 바이트도 쓰지 않는다.  화면에도 안 그린다.

local LABEL  = "neokobe"
local CHANGE = 4       -- 살아 있는 종류가 이만큼 새로 생기면 장면이 바뀐 것으로 본다
local COOL   = 120     -- 스냅샷 사이 최소 간격 (프레임).  같은 장면을 여러 번 안 뜨게

local VRAM = emu.memType.pceVideoRam
local CRAM = emu.memType.pcePaletteRam
local SPR  = emu.memType.pceSpriteRam

local OUT = "C:/snatcher/dump"
local prefix = OUT .. "/sprite_" .. LABEL .. "_" .. os.date("%Y%m%d_%H%M%S")

local frame = 0
local seen, seen_n = {}, 0      -- 누적 목록
local live_prev = {}            -- 직전 프레임에 살아 있던 집합
local scenes = {}
local last_snap = -99999

local function byte(mem, at) return emu.read(at, mem) or 0 end
local function word(mem, at) return byte(mem, at) | (byte(mem, at + 1) << 8) end

local function write_binary(path, mem, at, n)
  local f = io.open(path, "wb")
  if f == nil then emu.log("★ 못 연다: " .. path) return false end
  local t = {}
  for i = 0, n - 1 do t[#t + 1] = string.char(byte(mem, at + i)) end
  f:write(table.concat(t)); f:close()
  return true
end

local function decode(slot)
  local at = slot * 8
  local y, x = word(SPR, at), word(SPR, at + 2)
  local p, a = word(SPR, at + 4), word(SPR, at + 6)
  if (y | x | p | a) == 0 then return nil end
  local hc = (a >> 12) & 3
  return {
    slot = slot, pat = (p & 0x07FF) * 32,
    w = ((a & 0x0100) ~= 0) and 32 or 16,
    h = (hc == 0 and 16) or (hc == 1 and 32) or 64,
    pal = a & 0x0F, front = ((a & 0x0080) ~= 0),
    sx = (x - 0x20) & 0xFFFF, sy = (y - 0x40) & 0xFFFF,
  }
end

local function snapshot(n_new)
  local vp = string.format("%s_vram_f%06d.bin", prefix, frame)
  local cp = string.format("%s_cram_f%06d.bin", prefix, frame)
  if not write_binary(vp, VRAM, 0, 0x10000) then return end
  write_binary(cp, CRAM, 0, 0x400)
  scenes[#scenes + 1] = string.format("%d\t%d\t%s\t%s",
    frame, n_new, vp:match("[^/]+$"), cp:match("[^/]+$"))
  last_snap = frame
  emu.log(string.format("  [%s] 장면 %d · 프레임 %d · 새 스프라이트 %d 종 -> _vram_f%06d.bin",
    LABEL, #scenes, frame, n_new, frame))
end

local HEAD = "pattern_word\twidth\theight\tpalette\tpriority\tscreen_x\tscreen_y\t"
          .. "slot\tfirst_frame\tlast_frame\tframes\n"

local function line(s, first, last, n)
  return string.format("%04X\t%d\t%d\t%d\t%s\t%d\t%d\t%d\t%d\t%d\t%d\n",
    s.pat, s.w, s.h, s.pal, s.front and "front" or "back",
    s.sx, s.sy, s.slot, first, last, n)
end

local function scan()
  local live, fresh = {}, 0
  for slot = 0, 63 do
    local s = decode(slot)
    if s then
      local k = string.format("%04X|%d|%d|%d", s.pat, s.w, s.h, s.pal)
      live[k] = true
      if not live_prev[k] then fresh = fresh + 1 end
      local e = seen[k]
      if not e then
        seen[k] = { s = s, first = frame, last = frame, n = 1 }
        seen_n = seen_n + 1
      else
        e.last = frame; e.n = e.n + 1
        if s.sx < 512 and e.s.sx >= 512 then e.s = s end
      end
    end
  end
  live_prev = live
  -- ★ 장면 전환: 새로 뜬 종류가 많으면 그 자리에서 VRAM 을 뜬다
  if fresh >= CHANGE and frame - last_snap >= COOL then snapshot(fresh) end
end

local function dump(reason)
  local list = {}
  for _, e in pairs(seen) do list[#list + 1] = e end
  table.sort(list, function(a, b)
    if a.first ~= b.first then return a.first < b.first end
    if a.s.sy ~= b.s.sy then return a.s.sy < b.s.sy end
    return a.s.sx < b.s.sx
  end)
  local f = io.open(prefix .. "_sprites.tsv", "w")
  if f ~= nil then
    f:write(HEAD)
    for _, e in ipairs(list) do f:write(line(e.s, e.first, e.last, e.n)) end
    f:close()
  end
  local g = io.open(prefix .. "_sprites_last.tsv", "w")
  if g ~= nil then
    g:write(HEAD)
    for slot = 0, 63 do
      local s = decode(slot)
      if s then g:write(line(s, frame, frame, 1)) end
    end
    g:close()
  end
  local h = io.open(prefix .. "_scenes.tsv", "w")
  if h ~= nil then
    h:write("frame\tnew_sprites\tvram_file\tcram_file\n")
    h:write(table.concat(scenes, "\n"))
    h:write("\n")
    h:close()
  end
  emu.log(string.format("SPRITE CAPTURE 0.8.3 [%s] %s · 프레임 %d · 스프라이트 %d 종 · 장면 %d 개",
    LABEL, reason, frame, seen_n, #scenes))
end

emu.addEventCallback(function()
  frame = frame + 1
  scan()
  if frame % 600 == 0 then dump("auto") end
end, emu.eventType.startFrame)

-- ★ F 를 누른 그 순간을 반드시 남긴다 (0.8.2 가 빠뜨린 것)
emu.addEventCallback(function()
  snapshot(0)
  dump("key_F")
end, emu.eventType.codeBreak)

emu.log("GFX SPRITE CAPTURE 0.8.3  [" .. LABEL .. "]  읽기 전용")
emu.log("  ★ 장면 전환마다 + F 를 누른 그 순간에도 VRAM/CRAM 을 뜬다")
emu.log("  ★ 보고 싶은 화면이 떠 있을 때 F 를 누를 것 -- 그 프레임이 남는다")
emu.log("  -> " .. prefix .. "_*")
