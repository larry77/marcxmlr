# Experimental C4 optimization round 2

This work is experimental and is **not** invoked by public `read_marcxml()` or
`marcxml_to_parquet()` without filters. The previous C4 DOM implementation is
preserved as a reference.

## Questions

- Is `xmlFreeDoc()` and the allocation of a full selected-record batch tree
  responsible for C4's permissive-filter slowdown?
- Can binding the known homogeneous 11-column canonical batches directly in C
  reduce the ~0.48-second in-memory aggregation cost?

## Two independent switches

For the unexported `.prototype_c4_native_read_offsets()`:

- `.engine = "dom"` (original) vs `.engine = "reader"` (new): the reader
  processes selected records one by one via `xmlTextReaderExpand()` and reuses
  existing `count_record_node()` / `write_record_node()`. Capacity of each
  canonical batch grows geometrically if necessary; the existing input batch
  bounds still apply. The reader never constructs a full-batch XML DOM.
- `.binding = "purrr"` (original) vs `.binding = "native"` (new): a C function
  copies the 11 homogeneous canonical columns into final R vectors, bypassing
  `purrr::list_rbind()` for experimental in-memory output only. Parquet output
  still writes bounded canonical batches individually and needs no binding.

This gives four independently testable combinations. The defaults are unchanged
(`dom` + `purrr`), so the new code is opt-in even within the experimental API.

## Verification and benchmark

First run the focused correctness tests:

```
R CMD INSTALL . && R -q -e 'testthat::test_local(".", filter = "experimental-c4-round2", reporter = "summary")'
```

For the problematic `650` filter (permissive), run:

```
Rscript tools/c4-offset/benchmark-c4-round2.R \
  ~/marcxmlr-repro/benchmark-inputs/cataloging-records-all-cgp-XML-00.xml 3 650
```

The script checks exact canonical equality for each combination, then measures
C1 and all four combinations on the same machine. Results are written into a
home-directory `marcxmlr-c4-round2-*` folder as correctness.csv, raw.csv,
summary.csv, environment.txt. To test all three selectivities, set the last
argument to `856,710,650`.

**Limitations:** Peak memory is not measured. In the streaming implementation,
output buffers may temporarily have unused capacity before they are shrunk. The
original C4 restricted UTF-8/namespace input assumptions still apply. Do not
interpret a decrease in `native_cleanup_s` in isolation: the total elapsed time
is the final criterion, since work could simply move into XML reader advancement.
