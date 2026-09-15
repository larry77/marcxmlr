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

## Native record-chunk optimisation

This development branch starts from marcxmlr commit
`6882b8328131a5a1efabbf36c895e34cdafe04ca` and applies the native-engine design
examined in xmlrectr commit `5ebdffd34056c05a9d336a93dab0f8b6d7fc6d66`.

The transferable techniques are direct libxml2 tree traversal, counting before
allocating output columns, amortising R/C calls across records, and hash-based
occurrence counters. The C implementation is MARC-specific: it does not import
xmlrectr's generic node table, analyst projection, profiles, automatic scheduler,
or its package dependency. The implementation was written for this package;
no GPL-licensed xmlrectr source was copied into the MIT package.

### Preserved contract

- Both exported functions retain exactly the same arguments and defaults.
- All eleven output columns retain their order, types, missing values, and
  meanings. Field occurrence keys include field type and tag; subfield counters
  reset within each data field. Arbitrary tag/code strings remain supported.
- The existing file reader, record serialization, namespace repair, n_max
  selection, task scheduling, mori sharing, future-plan restoration, SAX
  buffering, Parquet compression, staging and final publication stay in R.
- Native code receives complete owned strings, never xml2 external pointers.
- Native batches contain at most 256 records, independently of public task and
  streaming batch sizes. The native parser does not retain a whole catalogue
  DOM or change the number of Parquet parts.
- The original record parser is retained unchanged. Native code declines
  unsupported or invalid structures and any parser warning/error; the entire
  original task is then evaluated through the existing R path. This preserves
  validation precedence and purrr's indexed error conditions. It is not a
  permissive/recovering XML parser.

### Native ownership and builds

`src/marcxml-native.c` registers its .Call entry point, disables dynamic lookup,
and requires registered native symbols. It links to system libxml2 without
accessing xml2's private pointer representation. `R_ExecWithCleanup()` releases
all owned XML documents, parser contexts, and temporary XML text on ordinary
return, errors, and interrupts. Error suppression is local to the owned parser;
it must not replace libxml2's global handlers used by XML/xml2.

Source builds need libxml2 headers and a C compiler. Unix configuration first
accepts explicit `INCLUDE_DIR`/`LIB_DIR`, then `xml2-config`, then `pkg-config`.
The configure probe verifies both compilation/linking and the declared
libxml2 >= 2.9.0 floor. The macOS legacy `/usr/include` case follows the
static autobrew fallback used by the current `xml2` package rather than
forcing a second shared libxml2 into R.app.

On Windows, modern Rtools installations use their `pkg-config` libxml2 entry.
If that entry is unavailable, `Makevars.win` and `tools/winlibs.R` use the
same r-windows bundle strategy as the current `xml2` package, including its
R 4.1/Rtools40 fallback. A generated `windows/` directory is excluded from
source packages and version control. These build paths still require actual
CI/machine execution; static Linux review does not establish Windows/macOS
runtime compatibility. The minimum declared R version remains 4.1.

libxml2 2.12 changed the structured-error callback to take `const xmlError *`,
but `xmlCtxtSetErrorHandler()` itself was only added in libxml2 2.13. The native
parser therefore uses separate version guards for the callback signature and
for the newer per-context setter; 2.9--2.12 use the parser context's SAX
`serror` slot.

### Regression and benchmark commands

```sh
R CMD build marcxmlr
R CMD check --no-manual marcxmlr_0.1.0.9000.tar.gz
Rscript -e 'testthat::test_local("marcxmlr")'
RUN_MARCXML_PARALLEL_TESTS=true Rscript -e 'testthat::test_local("marcxmlr")'
Rscript marcxmlr/inst/benchmarks/benchmark-native.R
MARCXML_BENCH_FILE=/path/to/public.xml Rscript marcxmlr/inst/benchmarks/benchmark-native.R
MARCXML_REFERENCE_DIR=/path/to/original-checkout Rscript marcxmlr/inst/benchmarks/benchmark-native.R
```

`options(marcxmlr.native = FALSE)` is an internal developer-only switch for
comparison with the original R parser. It is not a new exported engine API.
Restore the previous option after testing. Tests require native-vs-reference
identity, including namespace/attribute edge cases, entities, CDATA, whitespace,
Unicode, repeated and arbitrary occurrence keys, IDs crossing native/public
batch boundaries, and identical error conditions. A dedicated regression test
also checks that the prefix-free `namespace-uri(.)` XPath returns exactly the
same values with `ns = character()` as with xml2's default namespace discovery.
A 4,096-subfield single-record stress case covers long occurrence runs,
combining characters and non-BMP Unicode. The C entry point is also exercised
directly to prove that ordinary fixtures use native execution rather than
silently falling back. A small GC stress check exercises native protection.

Before a release candidate, run the native suite under a memory checker on a
normal Linux machine as an additional gate. For example, with `valgrind`
installed:

```sh
R -d "valgrind --tool=memcheck --leak-check=full --track-origins=yes" \
  --vanilla -e 'testthat::test_local(".")'
```

This diagnostic is deliberately not part of ordinary `R CMD check`; it is a
release-validation step. It was not executable in the restricted review
environment used for this branch.

The benchmark reports parsing alone and end-to-end `read_marcxml()` separately,
using medians from both paths on the same machine. It requires `identical()`
before reporting a speedup. Without an input file it generates 2,000 records by
repeating the bundled example: this is a synthetic benchmark, not a claim about
large real-world catalogues. Downloaded/private data and machine-specific paths
must remain outside the repository.

A separate R-side optimisation passes `ns = character()` to the collection's
`namespace-uri(.)` XPath call. This prefix-free XPath requires no registered
namespace bindings; the namespace URI it returns is unchanged. The default
`xml_ns(records)` discovery can repeatedly scan the same document through a
nodeset, dominating runtime even after native record parsing is fast. The
internal native on/off benchmark shares this optimisation in both paths;
compare with the recorded baseline Git commit for a full before/after measure.
