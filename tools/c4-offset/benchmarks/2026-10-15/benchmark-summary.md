# `marcxmlr` selective record filtering: C4 offset prototype benchmark

**Run:** 2026-10-15 15:07:49 CEST  
**Source dataset:** `cataloging-records-all-cgp-XML-00.xml` (187,829,283 bytes; 40,000 source records)  
**Environment:** R 4.6.1, `marcxmlr` 0.4.0, Linux x86_64 (`7.2.5-custom`).  
**Benchmark design:** Five timed repetitions per method and tag, preceded by one warm-up; methods randomized per repetition with a fixed seed; `gc()` before each timed call; all timings in the same R process; wall-clock seconds measured with `system.time()`. Correctness comparison performed before timing and excluded from measurements.

## Implementations

- **A_full:** Parse all input with `marcxmlr::read_marcxml()`, then retain complete records containing the specified tag.
- **C1:** Existing experimental selective two-pass filter.
- **C4_offset:** Standalone Expat XML byte-range scanner, R direct seek and temporary MARCXML collection, parsed with `marcxmlr::read_marcxml()`.

## Correctness

`identical()` on the **entire canonical 11-column table** was `TRUE` between A_full, C1 and C4, after consecutively renumbering artificial `record_id`. Indexed record counts also matched C1 in all three cases.

| Tag | Selected source records | Selection share | Canonical rows | A = C1 | C1 = C4 | Index count = C1 |
|---|---:|---:|---:|:---:|:---:|:---:|
| `856` | 122 | 0.305% | 7,993 | TRUE | TRUE | TRUE |
| `710` | 18,360 | 45.900% | 1,068,590 | TRUE | TRUE | TRUE |
| `650` | 34,907 | 87.268% | 1,899,368 | TRUE | TRUE | TRUE |

## Performance (median elapsed seconds; five runs)

| Tag | A_full | C1 | C4_offset | C4 time saved vs C1 | C4 time saved vs A |
|---|---:|---:|---:|---:|---:|
| `856` | 7.375 s | 4.541 s | **2.164 s** | **52.3%** | **70.7%** |
| `710` | 6.577 s | **5.277 s** | 5.406 s | **-2.4%** | 17.8% |
| `650` | **7.741 s** | 6.604 s | 8.424 s | **-27.6%** | **-8.8%** |

Positive time saved means C4 is faster; negative means C4 is slower. Each number is the median of its own five repetitions, so medians of constituent phases need not add exactly to median total time.

### C4 phase timings (median seconds)

| Tag | XML screening | Direct retrieval + selected-record parsing | Overall C4 |
|---|---:|---:|---:|
| `856` | 2.133 | 0.030 | 2.164 |
| `710` | 1.910 | 3.443 | 5.406 |
| `650` | 1.879 | 6.264 | 8.424 |

## Findings and caveats

1. **Selectivity strongly matters.** At 0.305% selection C4 is about **2.10x faster than C1**; at 45.9% the two are similar, and at 87.3% C4 loses substantially.
2. The direct-access *mechanism* is validated for these tests, and C4 avoids processing rejected records with the full MARC parser. The R proof of concept additionally creates a temporary MARCXML collection for accepted records; this overhead increases sharply as the retained set grows.
3. The measured screening cost is roughly 1.9–2.1 s across tags, consistent with examining the entire input once. The selected-record retrieval/parsing cost scales with retained output volume.
4. **These are controlled within-machine comparisons, not performance guarantees for other machines or files.** Five runs are enough to establish promising trends, not confidence intervals.
5. No peak RAM measurement was made; in particular, C4's memory advantages over C1 remain unmeasured in this experiment. No out-of-memory Parquet filtering was tested.
6. The stand-alone C4 prototype currently assumes uncompressed UTF-8 MARCXML without a DTD, and reconstructs fragments using the standard MARCXML namespace. Broader XML and encoding support needs validation before integration.
7. This does **not** modify or benchmark the existing unfiltered native implementation under a new filter/no-filter dispatch. The design requirement remains: no filter supplied => original code path unchanged.

## Reproducibility

Original uploaded benchmark outputs: `correctness.csv`, `raw.csv`, `summary.csv`, `summary_by_method.csv`, `environment.txt` and `README.txt` (run date above). The driver was `benchmark-marcxmlr-offset-v1.R`, using the R/Expat offset prototype from `marcxmlr-offset-r-demo`.

**Recommended next engineering question:** Can C4's byte-offset direct-access approach be integrated natively for both in-memory and bounded-memory Parquet output, without the temporary R-assembled XML collection, while keeping the existing fast unfiltered path unchanged? Benchmark both rare and common filters after integration.
