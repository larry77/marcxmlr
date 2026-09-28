## Update submission

This is an update of `marcxmlr` from version 0.2.1 to 0.3.1.

The update adds MARCXML writing, including gzip-compressed `.xml.gz` output, while preserving the existing canonical representation and reading interfaces.

## Test environments

* local Debian GNU/Linux, R 4.6.1
* GitHub Actions, Ubuntu, R-devel
* GitHub Actions, Ubuntu, R-release, including optional parallel tests
* GitHub Actions, Windows, R-release
* GitHub Actions, macOS, R-release
* GitHub Actions, Ubuntu 22.04, R 4.1, sequential core with hard dependencies

## R CMD check results

0 errors | 0 warnings | 0 notes

The submitted source tarball was checked locally with `R CMD check --as-cran`.

## Additional testing

The package test suite includes round-trip MARCXML serialization, gzip-compressed MARCXML input and output, Arrow-backed writing, sharding, malformed-input handling, and portability checks across Linux, Windows, and macOS.

Large-file development tests use public U.S. Government Publishing Office MARCXML data and are not included in `R CMD check`.
