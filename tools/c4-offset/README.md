# C4: byte-offset record selection (experimental, standalone)

This directory preserves the Oct 15, 2026 C4 direct-access proof of concept, benchmark code, raw results and checkpoint note. It is **not** part of the package's public API, and no production native parser path is changed. Keep it on the `prototype-record-filter` branch.

## Contents

- `record_offset_index.c`: standalone XML-aware Expat scanner reporting matching record source positions and byte spans; compiled automatically into a temporary executable.
- `marcxmlr-offset-test.R`: corrected R wrapper that reads selected byte spans into a temporary MARCXML collection and runs the installed `marcxmlr::read_marcxml()` on it. Supports prefixed MARC namespace in the tested GPO data.
- `benchmark-marcxmlr-offset-v1.R`: A / C1 / C4 exact-equality benchmark. Resolves the R wrapper relative to its own script path, so it works after a Git clone on another machine.
- `profile-c4-stages.R`: diagnostic to separate C4's scan, index loading, **R record copying**, and **native MARCXML parsing**. Important for diagnosing poor performance with broad filters.
- `benchmarks/2026-10-15/`: original correctness, raw timings, summaries, machine environment and a written benchmark report.

Prerequisites: R, installed `marcxmlr` built from the `prototype-record-filter` experimental branch, C compiler `cc`, Expat development library (`libexpat1-dev` on Debian), ordinary UTF-8 uncompressed MARCXML without DTD. The wrapper currently supports standard MARC 21 namespace (default and `marc:` prefix). The scanner's XML well-formedness and offset bookkeeping do not imply full MARC validation of records discarded by filtering.

Run the benchmark (five repetitions per method) from the Git working copy:

```sh
Rscript tools/c4-offset/benchmark-marcxmlr-offset-v1.R \
  ~/marcxmlr-repro/benchmark-inputs/cataloging-records-all-cgp-XML-00.xml 5
```

To diagnose C4's expense for less restrictive filters, profile **the R temporary-collection construction separately from the native parser**:

```sh
Rscript tools/c4-offset/profile-c4-stages.R \
  ~/marcxmlr-repro/benchmark-inputs/cataloging-records-all-cgp-XML-00.xml 3
```

These scripts save dated results directories under `~` and do not alter the package source or the input file. Input data are **not** included in Git; ensure the 40k-record GPO dataset is available on the machine where benchmarks run. Do not compare absolute times measured on different machines.

## Established findings

The exact 11-column canonical output agrees across A, C1 and C4 for three test filters. Median times (40,000 GPO records, five repetitions, same Linux machine):

| Tag | Selected | A full | C1 | C4 | C4 vs C1 |
|---|---:|---:|---:|---:|---:|
| 856 | 122 (0.3%) | 7.375 s | 4.541 s | 2.164 s | 52.3% faster |
| 710 | 18,360 (45.9%) | 6.577 s | 5.277 s | 5.406 s | 2.4% slower |
| 650 | 34,907 (87.3%) | 7.741 s | 6.604 s | 8.424 s | 27.6% slower |

## Next engineering questions

1. **Determine the measured cost** of C4's R loop of `seek`/`readBin`/`writeBin` calls versus native `read_marcxml()` of the resulting temporary XML. Avoid assuming which dominates before profiling.
2. If copying is expensive, prototype batched native C extraction/processing from selected offsets, **without one R call per record** and without an all-selected-records temporary XML collection.
3. For broad filters, evaluate a sequential pass over selected records rather than tens of thousands of independent seeks. Eventually choose direct seeks versus sequential selected-record processing based on matched record/byte fraction and clustering, using same first-pass screening where feasible.
4. For out-of-memory output, stream bounded groups of selected records to `marcxml_to_parquet()` machinery without allocating all selected rows or collecting all selected fragments in R.
5. No filter supplied: **use the existing native reader/Parquet paths completely unchanged**, with no additional screening or dispatch overhead inside their record-processing loops.

C4 is a proof of concept; no claim of production-grade portability or universal performance advantage.

## Native C4 materialization prototype (after 2026-10-15 checkpoint)

The additional experimental `C_marcxml_offset_parse_batch()` native entry point
receives selected source byte ranges. It seeks/reads the original bytes in C,
builds **one bounded in-memory XML collection per batch** (no temporary XML
file), and uses the established `count_record_node()` and
`write_record_node()` native functions for the selected records only.

The experimental R entry points are:

- `marcxmlr:::.prototype_c4_native_read_offsets(file, offsets)`
- `marcxmlr:::.prototype_c4_native_to_parquet_offsets(file, offsets, output_dir)`

Both accept the data.frame produced by the Expat `record_offset_index` helper.
These functions intentionally do **not** alter `read_marcxml()` or
`marcxml_to_parquet()`; no-filter calls use their existing native paths.

To run **both the old C4 stage profile and a controlled C1 / old C4 /
native C4 comparison in a single experiment**, install this experimental
package snapshot (`R CMD INSTALL .`), then run:

```sh
Rscript tools/c4-offset/profile-and-benchmark-c4-native.R \
  ~/marcxmlr-repro/benchmark-inputs/cataloging-records-all-cgp-XML-00.xml 3
```

Check `correctness.csv` first. `raw.csv` contains both R-based extraction and
native stage timings; `summary.csv` contains median totals. The native stage
separates native file IO, libxml2 tree parse, MARC counting and canonical writing
(Linux monotonic clock; on other platforms stage readings may be zero).

### Prototype restrictions

- The **separate** Expat index helper is still used for screening; integration
  of screening into the installed package is not part of this experiment.
- Uncompressed UTF-8, DTD-free MARCXML with standard namespace (default or
  `marc` prefix), as in the tested GPO inputs. Arbitrary inherited prefixes,
  entity declarations, encodings and compressed files require more work.
- Record offsets must be ordered and non-overlapping and are expressed as
  zero-based byte positions. Output record IDs are consecutive from 1.
- Parquet output uses bounded canonical batches, but the complete **offset
  index** is currently kept in R memory; further streaming work is needed for
  huge numbers of selected records.
- The native batch builds a bounded in-memory libxml2 tree; there is no
  assertion that this will outperform C1 for permissive filters. Compare it.
- No peak RSS comparison is made by the supplied benchmark.

## C4 native residual profiling (separate follow-up experiment)

To locate the permissive-filter penalty, a profiling-only extension to the
experimental native reader separates canonical vector allocation, per-cell NA
initialization, canonical row writing, and XML document cleanup. The R wrapper
also times native `.Call`, tibble construction, batch consumption, final batch
binding, and unclassified wrapper work. **The public unfiltered functions are
not altered.**

Run after `R CMD INSTALL .`:

```sh
Rscript tools/c4-offset/profile-c4-native-residual.R \
  ~/marcxmlr-repro/benchmark-inputs/cataloging-records-all-cgp-XML-00.xml 5 650
```

Default is five runs of the permissive `650` case. Pass `650,710,856` as the
third argument to profile all three cases. The script checks **exact canonical
equality** before timing, then writes `correctness.csv`, `raw.csv`,
`summary.csv` and `environment.txt` under `~/marcxmlr-c4-residual-<timestamp>/`.
This diagnostic experiment does not measure peak memory or Parquet output.
Per-phase medians are not strictly additive, and profiling itself has overhead.
