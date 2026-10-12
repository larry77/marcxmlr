## Update submission

This is an update of `marcxmlr` from version 0.3.1 to 0.4.0.

The main changes are:

* Native recovery from structurally malformed MARC records, with optional
  whole-record skipping and an audit report containing the original record XML.
  XML syntax and encoding errors remain fatal.
* Extension of `diagnose_canonical()` to Arrow Datasets and lazy Arrow queries,
  allowing bounded-memory structural validation without collecting the
  complete dataset.

The existing canonical representation and default strict parsing behaviour
remain unchanged.

## Test environments

* Local Debian GNU/Linux, R 4.6.1
* GitHub Actions, Ubuntu, R-devel
* GitHub Actions, Ubuntu, R-release, including optional parallel tests
* GitHub Actions, Windows, R-release
* GitHub Actions, macOS, R-release
* GitHub Actions, Ubuntu 22.04, R 4.1, sequential core with hard dependencies

## R CMD check results

0 errors | 0 warnings | 0 notes

The source package was checked locally using `R CMD check --as-cran`.
All GitHub Actions checks passed.

## Additional testing

The complete test suite passed locally, including optional parallel tests:
468 passed, 0 failures, 0 warnings, 0 skipped.

Large-file development tests used public U.S. Government Publishing Office
MARCXML data, including a file containing a malformed MARC record. These tests
verified native recovery, Parquet conversion, preservation of source record
identifiers, and out-of-memory diagnostics. They are not included in
`R CMD check`.
