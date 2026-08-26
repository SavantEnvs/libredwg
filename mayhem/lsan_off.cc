// Disable LeakSanitizer at build time (ASan and UBSan stay fully active); linked into every fuzz and -standalone binary.
extern "C" int __lsan_is_turned_off() { return 1; }
