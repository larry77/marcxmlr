# Development checks

The package metadata currently contains a placeholder author and email. Replace
the `Authors@R` entry in `DESCRIPTION` and the copyright holder in `LICENSE`
before publishing the repository or submitting to CRAN.

## Standard checks

From the directory above the package:

```r
install.packages(c(
  "arrow", "dplyr", "future", "future.mirai", "futurize", "furrr", "mori",
  "testthat", "XML"
))

devtools::document("marcxmlr")
devtools::test("marcxmlr")
devtools::check("marcxmlr")
```

The standard test suite exercises sequential in-memory parsing and sequential
streaming conversion. Optional parallel tests are disabled by default so that
ordinary checks do not unexpectedly create worker processes. Run them with:

```r
Sys.setenv(RUN_MARCXML_PARALLEL_TESTS = "true")
testthat::test_local("marcxmlr")
Sys.unsetenv("RUN_MARCXML_PARALLEL_TESTS")
```

## Public large-file benchmark

The package includes `inst/benchmarks/benchmark-public.R`. Point it at a public
MARCXML collection without placing that input inside the package:

```r
Sys.setenv(
  MARCXML_BENCH_FILE = "/path/to/public-records.xml",
  MARCXML_BENCH_OUTPUT = "/path/to/new-parquet-directory"
)

source("marcxmlr/inst/benchmarks/benchmark-public.R")
```

Never add private MARCXML inputs, derived rows, local benchmark paths, or
private benchmark results to the package or repository.
