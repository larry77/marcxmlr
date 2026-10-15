Benchmark definition:
  A_full: marcxmlr::read_marcxml(file), then retain complete records containing the tag.
  C1: experimental .prototype_read_marcxml_filtered() selective two-pass reader.
  C4_offset: standalone Expat indexer -> R byte seeking -> temporary XML collection -> marcxmlr::read_marcxml().
  Tags: 856 (rare), 710 (intermediate), 650 (common).
  Correctness: TRUE means identical() on full 11-column canonical tables, after consecutively renumbering artificial record_id.
  Three comparisons (full vs C1, C1 vs C4, and index count vs C1) are checked for EACH tag before timing.
  All recorded timings exclude that one-time canonical equality verification.
  Each method receives one warm-up per tag. Repetition order is randomized.
  Reported time gains are 100*(reference - C4)/reference, based on medians.
  Positive time gain means C4 was faster. Negative time gain means slower.
  C4 is a proof of concept, not an integrated native implementation.
  C4 input restrictions: uncompressed UTF-8 MARCXML without DTD; fragment reconstruction assumes standard MARCXML namespace.
  This run does NOT measure peak memory usage.
