# Experimental MARCXML record screening (not public API)

This is a **prototype**, isolated from `read_marcxml()` and
`marcxml_to_parquet()`. It has **not** been verified by running R package
checks in the present environment. Do not merge it into a release without
compilation, tests, and performance investigation.

## Architecture

- An opt-in native `xmlTextReader` first pass validates every included MARC
  record and computes its complete canonical row count.
- It copies only the requested MARC tags into a temporary nine-column table,
  bounded by `screen_batch_records` complete records. Unrequested fields do not
  contribute values to that table.
- A user-supplied R function (which may use `dplyr`) receives that table and
  all source `record_ids` in the batch. It returns a logical vector with one
  non-missing keep/discard decision per input record.
- The first pass stores the selected source positions and planned row counts.
  The existing native sparse-record writer (originally used for MARC recovery)
  then makes a second pass over the XML to materialize **complete retained
  records** with the original source `record_id`s.
- Existing unfiltered readers are unchanged, including their native entrypoints
  and hot paths. No additional work occurs in an ordinary unfiltered call.

## Example — select complete records with matching 650 subfields

```r
library(marcxmlr)
file <- system.file("extdata", "example-marcxml.xml", package = "marcxmlr")

result <- marcxmlr:::.prototype_read_marcxml_filtered(
  file,
  filter_tags = "650",
  screen_batch_records = 1000L,
  record_filter = function(x, record_ids) {
    matches <- x |>
      dplyr::filter(subfield_code == "a", grepl("Metadata", value)) |>
      dplyr::distinct(record_id) |>
      dplyr::pull(record_id)
    record_ids %in% matches
  }
)
```

The screening table columns are `record_id`, `field_type`, `tag`,
`subfield_code`, `value`, `field_order`, `ind1`, `ind2`, and `subfield_order`.
A record with none of the requested tags is still present in `record_ids` and
can therefore be selected by an absence condition.

For an experimental Parquet output (requires Arrow):

```r
marcxmlr:::.prototype_marcxml_to_parquet_filtered(
  file, tempfile("selected-parquet-"),
  filter_tags = c("100", "650"),
  record_filter = function(x, record_ids) {
    record_ids %in% x$record_id[
      x$tag == "100" & x$subfield_code == "a"
    ]
  }
)
```

## Scope and known limitations

- **Experimental only:** no public signature changes, no Roxygen/man updates,
  and no new CRAN-facing API.
- Native-supported strict MARCXML input only. No XML2 compatibility fallback,
  parallel worker support, MARC-error recovery, or multi-file conversion yet.
- The first pass scans the source XML completely and validates included
  records. Selective exposure avoids copying unrelated field values to R, **not**
  parsing the XML or expanding individual MARC record nodes in libxml2.
- Record filters are arbitrary R functions, not SQL expressions. Filters may
  use `dplyr` but must return one logical decision per record. Repeated fields
  can be distinguished with `(record_id, field_order)`.
- The filtering callback works **per batch** and should not make assumptions
  about global statistics over the complete input unless those have already
  been supplied externally.
- The Parquet prototype stages its output, but is not a drop-in replacement
  for the production multi-file and error-reporting machinery.
- Source files should remain unchanged between the screening and writing
  passes, as with the existing two-pass native parser.
- Correctness and performance have **not yet been verified in an R runtime**.
  Specifically test the new native callbacks under valgrind or sanitizers and
  compare selective screening against full canonical batch filtering before
  considering any production integration.

## Experimental phase profiling (Linux only)

The internal `.prototype_profile_marcxml_filtered()` function enables a
monotonic-clock timing layer that is inactive for normal filtering and absent
from the public parser. It returns `list(result, timings, counts)`; `result`
is the complete selected canonical tibble, identical to the unprofiled
prototype. The native timers instrument:

- The first-pass screening calls (`screen_native_s`), including `screen_validate_s`
  (record expansion and complete-record row counting), `screen_extract_s`
  (selective field extraction), and `screen_pack_s` (constructing R vectors and
  freeing temporary screening rows).
- The R predicate callbacks (`r_filter_callback_s`).
- The second-pass recovery reader calls (`second_native_s`), including
  `second_revalidate_s` and `second_write_s`.
- The final binding of canonical batches (`bind_s`).

The `screen_native_other_s` and `second_native_other_s` columns are *residuals*,
not isolated measurements of XML traversal. They include I/O, XML navigation,
allocation and native bookkeeping; the latter also includes scanning rejected
records. `plan_r_other_s`, `second_r_other_s`, and `total_other_s` are residuals
at the R boundary. The named nested subtimings **must not be summed together**.
Native monotonic timings exclude time outside the relevant `.Call` operation.
The reported total includes the R calls and final binding. They have measurement
overhead, and cannot be compared directly with uninstrumented stage-1/2 timings.

After installing the branch (`R CMD INSTALL .`), profile the 40,000-record GPO
input with:

```sh
Rscript tools/profile-filter-stage3.R \
  ~/marcxmlr-repro/benchmark-inputs/cataloging-records-all-cgp-XML-00.xml
```

The script verifies exact equality with ordinary full parsing and writes raw
per-run measurements and median phase timings under `~/marcxmlr-filter-profile-*`.
No baseline performance figures are overwritten. The first experiment measures
field-presence predicates only; value-based callbacks and filtered Parquet
workflows remain future experiments. Profiling may itself influence timings.
