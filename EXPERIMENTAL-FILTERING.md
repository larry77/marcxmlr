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
