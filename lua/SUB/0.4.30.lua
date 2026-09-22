-- SUB 0.4.30 -- true pre-subtitle 0.4.5.9 base + Lua-only ALLVOICE $1600.
--
-- Target disc:
--   C:/snatcher/build/patch/0.4.5.9-collection-base/
--   Snatcher CD-ROMantic (Japan) [KO 0.4.5.9-collection] (0824-2354).cue
--
-- This base has no subtitle preload.  Lua directly uploads the subtitle pack,
-- helper, and renderer to Arcade Card RAM, installs the old resident controller
-- when overlay A appears, and starts the same known two-fragment subtitle once
-- for every real rate-$0E ADPCM playback.  No $FEC4 BIOS subtitle gate is used.
--
-- Load this file only, after Power Cycle.  Do not load 0.4.27/0.4.29 with it.

SUB_RESIDENT_FORCE_BASE = 0x1600
SUB_RESIDENT_ALLVOICE = true
SUB_RESIDENT_PRELOAD_PACK = true
SUB_RESIDENT_LUA_RESTORE = true
SUB_RESIDENT_CONTROLLER_PATH =
  'C:/snatcher/build/cutscene_subs/resident_controller_0_7.bin'
SUB_RESIDENT_HELPER_PATH =
  'C:/snatcher/build/cutscene_subs/resident_helper_slot_native_poll_0_8_3.bin'
SUB_RESIDENT_RENDERER_PATH =
  'C:/snatcher/build/cutscene_subs/resident_renderer_slot_native_poll_0_8_4_r3.bin'
SUB_RESIDENT_PACK_PATH =
  'C:/snatcher/build/cutscene_subs/subtitle_pack.bin'

dofile('C:/snatcher/lua/PROBE_SUB_AC_RESIDENT_0_7_0.lua')

SUB_RESIDENT_FORCE_BASE = nil
SUB_RESIDENT_ALLVOICE = nil
SUB_RESIDENT_PRELOAD_PACK = nil
SUB_RESIDENT_LUA_RESTORE = nil
SUB_RESIDENT_CONTROLLER_PATH = nil
SUB_RESIDENT_HELPER_PATH = nil
SUB_RESIDENT_RENDERER_PATH = nil
SUB_RESIDENT_PACK_PATH = nil

emu.addEventCallback(function()
  emu.drawString(4, 34, '0.4.30 BASE459 LUA-ONLY $1600', 0x40FF40, 0x000000)
end, emu.eventType.endFrame)

emu.log('SUB 0.4.30 loaded -- 0.4.5.9 collection no-preload + Lua-only ALLVOICE')
emu.log('  pack/helper/renderer AC 직접 적재 · BIOS subtitle gate 사용 0')
emu.log('  같은 2줄 자막 · VRAM $1600-$1ABF · 음성 종료 후 Lua safety restore')
