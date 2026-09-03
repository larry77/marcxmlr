## First submission

This is the first submission of `marcxmlr`.

## Test environments

* local Debian GNU/Linux, R 4.6.1
* GitHub Actions, Ubuntu, R-devel
* GitHub Actions, Ubuntu, R-release, including optional parallel tests
* GitHub Actions, Windows, R-release
* GitHub Actions, macOS, R-release
* GitHub Actions, Ubuntu 22.04, R 4.1, sequential core with hard dependencies

## R CMD check results

0 errors | 0 warnings | 1 note

* This is a new submission.

## Data and tests

The package contains only a small synthetic MARCXML fixture. No private
catalogue, derived private data, or large integration input is included.
Large-file benchmarks use public data supplied separately by the user and are
not run during `R CMD check`.

The bounded-memory converter was also tested manually with a public U.S.
Government Publishing Office MARCXML collection containing 40,000 records and
producing 2,143,952 canonical rows. This external integration input is linked
from the README and is not included in the package.
