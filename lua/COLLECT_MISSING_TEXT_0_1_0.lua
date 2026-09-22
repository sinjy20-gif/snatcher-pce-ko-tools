-- Missing/untranslated dialogue only.  Voice, UI and frame probes stay off.
SNATCHER_TEXT_ONLY = true
SNATCHER_VISIBLE_MISS_ONLY = true
SNATCHER_TEXT_OUTPUT = "C:/snatcher/snatcher_tool/logs/runtime_missing_text_raw_v010.tsv"
dofile("C:/snatcher/lua/RUNTIME_TEXT_AUDIT_0.2.3_MISSONLY.lua")
