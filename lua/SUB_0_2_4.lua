-- SUB 0.2.4 -- one-file native loader + read-only order measurement.
-- This is the only Lua file to load for the current order test.
-- It deliberately uses the proven 0.8.3 native loader, then installs the
-- 0.2.3 read-only callbacks. It contains no allocator.
dofile('C:/snatcher/lua/LOAD_SUBTITLE_NATIVE_POLL_0_8_3.lua')
dofile('C:/snatcher/lua/SUB_0_2_3.lua')
emu.log('SUB 0.2.4 ready -- native engine load + order map / 이 파일 하나만 사용')
