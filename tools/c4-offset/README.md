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
