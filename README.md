# marcxmlr

<!-- badges will be added after the public repository and CI workflow exist -->

`marcxmlr` reads MARC 21 XML into R without discarding the structure that
makes MARC useful. It preserves repeated fields, repeated subfields,
indicators, record identity, and source order in a canonical 11-column long
table.

It provides two deliberately small workflows:

- `read_marcxml()` returns an in-memory tibble when the XML document and
  parsed result fit comfortably in memory.
- `marcxml_to_parquet()` streams a collection in bounded batches and writes
  an [Apache Parquet](https://parquet.apache.org/) dataset for catalogues that
  should not be materialized as one R object.

Parallel parsing is available but opt-in. The same MARC representation is
returned regardless of task size or worker count.

## What are MARC 21 and MARCXML?

[MARC](https://www.loc.gov/marc/faq.html#definition) means
*MAchine-Readable Cataloging*. MARC 21 is a family of communication formats
used to represent and exchange bibliographic and related information between
computer systems. It is coordinated by the Library of Congress in cooperation
with Library and Archives Canada and with input from libraries, library
networks, and library-system vendors worldwide. MARC data elements underpin
many library catalogues.

The five MARC 21 formats cover
[bibliographic](https://www.loc.gov/marc/bibliographic/),
[authority](https://www.loc.gov/marc/authority/),
[holdings](https://www.loc.gov/marc/holdings/),
[classification](https://www.loc.gov/marc/classification/), and
[community information](https://www.loc.gov/marc/community/) records. MARC 21
is principally an exchange format: it does not prescribe how a library system
must store or display its internal data.

A MARC record is ordered and hierarchical. It contains a leader, control
fields, and data fields. Data fields have two indicators and contain coded
subfields. Both fields and subfields can repeat, and their order can matter.
For example, flattening every `650$a` or `856$u` into one value loses
information about which field occurrence contained it and where it appeared.

[MARCXML](https://www.loc.gov/standards/marcxml/) is the Library of Congress
XML representation of MARC 21. The
[MARCXML design](https://www.loc.gov/standards/marcxml/marcxml-design.html)
represents tags and indicators as attributes and subfields as child elements,
while retaining the semantics needed for lossless conversion between MARCXML
and MARC in its ISO 2709 structure. MARCXML is used for complete records,
metadata exchange and harvesting, transformation, presentation, and analysis.

## Why another R package?

R has good XML and bibliographic software. The missing piece is a focused
combination of:

1. a documented MARC-aware tabular representation that never silently
   collapses repeated structure;
2. explicit field and subfield order and occurrence numbers;
3. the same representation for both in-memory and bounded-memory ingestion;
4. optional local parallel parsing without passing XML external pointers to
   workers; and
5. direct conversion of a large MARCXML collection into a lazily queryable
   Parquet dataset.

At the time of writing, the closest R-specific MARCXML project we found is
`maRc` on GitHub. [CRAN](https://CRAN.R-project.org/web/packages/) provides
strong generic XML and downstream bibliographic tools; searches of CRAN and
[Bioconductor](https://bioconductor.org/packages/release/bioc/) did not
identify this combined ingestion contract. Nearby tools solve different
problems:

| Tool | Intended role | Difference from `marcxmlr` |
|---|---|---|
| [`xml2`](https://xml2.r-lib.org/) | Modern general XML parsing and manipulation in R | Provides the XML tree and XPath machinery, but not MARC field semantics, occurrence columns, or a bounded-memory MARCXML-to-Parquet workflow. `marcxmlr` uses it for record parsing. |
| [`XML`](https://CRAN.R-project.org/package=XML) | General XML trees, XPath, event parsing, and SAX-style callbacks | Supplies the low-level streaming mechanism used internally by `marcxmlr`; users would otherwise need to implement record buffering, MARC semantics, schema stability, and output publication themselves. |
| [`maRc`](https://github.com/davidfuhry/maRc) | Reading and accessing MARCXML records through R6 record and data-field objects | Its documented interface is record-oriented. It does not document the canonical tidy collection representation or bounded-memory Parquet conversion provided here. |
| [`bibliometrix`](https://CRAN.R-project.org/package=bibliometrix) and [`revtools`](https://CRAN.R-project.org/package=revtools) | Bibliometric analysis and evidence-synthesis workflows | These are downstream tools for scientific-literature data and review workflows, rather than general structure-preserving MARCXML ingestion. |
| [`data-pond/marc21`](https://github.com/data-pond/marc21) | Node/TypeScript streaming CLI and library for category counts and extraction of selected records | It targets selected extraction and JSON output outside R, rather than a general canonical long table and an Arrow/Parquet analysis workflow in R. |

These differences are about scope, not defects in the other projects.
`marcxmlr` is intentionally a small MARCXML ingestion package, not a generic
XML framework, catalogue system, or bibliometric-analysis suite.

## Installation

Install the development version from GitHub with
[`remotes`](https://remotes.r-lib.org/):

```r
install.packages("remotes")
remotes::install_github("larry77/marcxmlr")
```

The in-memory reader uses the package's core dependencies. The streaming
workflow additionally requires `XML` and `arrow`:

```r
install.packages(c("XML", "arrow"))
```

The examples below use `dplyr` for querying and presentation:

```r
install.packages("dplyr")
```

Optional parallel parsing additionally requires:

```r
install.packages(
  c("future", "future.mirai", "futurize", "furrr", "mori")
)
```

## Small real-world example: Library of Congress

The Library of Congress publishes a
[MARCXML record for Carl Sandburg's *Arithmetic*](https://www.loc.gov/standards/marcxml/Sandburg/sandburg.xml).

### Download in a web browser

The example can be downloaded directly from the
[Library of Congress MARCXML site](https://www.loc.gov/standards/marcxml/Sandburg/sandburg.xml)
on Windows, macOS, or Linux. Save the page as `sandburg.xml` inside a
`data/loc` directory. If the browser displays the XML instead of downloading
it, use **Save page as** or **Save as**.

### Download from a Linux shell

With `curl`:

```bash
mkdir -p data/loc

curl --fail --location \
  "https://www.loc.gov/standards/marcxml/Sandburg/sandburg.xml" \
  --output data/loc/sandburg.xml
```

Or with `wget`:

```bash
mkdir -p data/loc

wget \
  "https://www.loc.gov/standards/marcxml/Sandburg/sandburg.xml" \
  -O data/loc/sandburg.xml
```

Read the complete record into memory:

```r
library(marcxmlr)

sandburg <- read_marcxml("data/loc/sandburg.xml")

sandburg |>
  dplyr::filter(tag == "245") |>
  dplyr::select(
    subfield_code,
    value,
    field_order,
    subfield_order
  )
#> # A tibble: 2 × 4
#>   subfield_code value                                      field_order subfield_order
#>   <chr>         <chr>                                            <int>          <int>
#> 1 a             Arithmetic /                                        12              1
#> 2 c             Carl Sandburg ; illustrated as an anamorphic...      12              2
```

The package also installs a small synthetic, prefixed-namespace collection.
Unlike a remote example, this file is stable and is therefore used in package
examples and tests:

```r
example_file <- system.file(
  "extdata",
  "example-marcxml.xml",
  package = "marcxmlr"
)

example <- read_marcxml(example_file)

dim(example)
#> [1] 18 11
```

Repeated subfields remain separate and ordered:

```r
example |>
  dplyr::filter(record_id == 1L, tag == "856") |>
  dplyr::select(
    subfield_code,
    value,
    subfield_order,
    subfield_occurrence
  )
#> # A tibble: 3 × 4
#>   subfield_code value                      subfield_order subfield_occurrence
#>   <chr>         <chr>                               <int>               <int>
#> 1 u             https://example.org/item/1              1                   1
#> 2 y             Full text                               2                   1
#> 3 y             Alternate access                        3                   2
```

`read_marcxml()` first builds the complete XML tree. Its `n_max` argument can
limit parsing for previews, but does not make XML ingestion itself streaming.

## Large public example: 40,000 GPO records

The U.S. Government Publishing Office (GPO) publishes the complete
[Catalog of U.S. Government Publications](https://catalog.gpo.gov/) as a
public [MARCXML repository](https://github.com/usgpo/cataloging-records-all-cgp-marcxml).
The February 2026 snapshot contains 1,115,162 records split across 28 ZIP
files, each holding approximately 40,000 records. The split makes one part a
manageable but realistic integration example.

GPO notes that the snapshot contains approximately 3,000 MARCXML validation
errors. This is useful real-world input: `marcxmlr` preserves and parses the
MARCXML structure, but it is not a complete MARC content or XSD validator.

### Download in a web browser

[Part `00`](https://github.com/usgpo/cataloging-records-all-cgp-marcxml/blob/main/Record_sets/cataloging-records-all-cgp-XML-00.xml.zip)
can be downloaded manually on Windows, macOS, or Linux:

1. Open the linked GitHub file page.
2. Select **Download raw file**.
3. Save the download as `gpo-00.xml.zip` inside a `data/gpo` directory.
4. Extract the ZIP file using Windows File Explorer, macOS Finder, or another
   archive manager.

The extracted file is named
`cataloging-records-all-cgp-XML-00.xml`. The
[GPO repository](https://github.com/usgpo/cataloging-records-all-cgp-marcxml)
also provides the other parts and catalogue documentation.

### Download from a Linux shell

The ZIP is stored with Git LFS, so command-line downloads must follow
redirects. With `curl`:

```bash
mkdir -p data/gpo

curl --fail --location \
  "https://github.com/usgpo/cataloging-records-all-cgp-marcxml/raw/refs/heads/main/Record_sets/cataloging-records-all-cgp-XML-00.xml.zip" \
  --output data/gpo/gpo-00.xml.zip

unzip -j data/gpo/gpo-00.xml.zip -d data/gpo
```

The equivalent download with `wget` is:

```bash
mkdir -p data/gpo

wget \
  "https://github.com/usgpo/cataloging-records-all-cgp-marcxml/raw/refs/heads/main/Record_sets/cataloging-records-all-cgp-XML-00.xml.zip" \
  -O data/gpo/gpo-00.xml.zip

unzip -j data/gpo/gpo-00.xml.zip -d data/gpo
```

The extracted input is:

```text
data/gpo/cataloging-records-all-cgp-XML-00.xml
```

The repository may later publish a refreshed catalogue. Exact row counts
below identify the February 2026 snapshot used during development.

### Convert MARCXML to Parquet without holding the catalogue in memory

Choose a new output directory. Existing directories are never overwritten:

```r
library(marcxmlr)

gpo_xml <- paste0(
  "data/gpo/",
  "cataloging-records-all-cgp-XML-00.xml"
)
gpo_parquet <- "data/gpo/gpo-00-parquet"

stopifnot(
  file.exists(gpo_xml),
  !dir.exists(gpo_parquet)
)

workers <- max(
  1L,
  as.integer(future::availableCores()) - 1L
)

conversion <- marcxml_to_parquet(
  gpo_xml,
  output_dir = gpo_parquet,
  batch_records = 5000L,
  workers = workers
)

conversion |>
  dplyr::select(records, rows, batches)
#> # A tibble: 1 × 3
#>   records    rows batches
#>     <int>   <dbl>   <int>
#> 1   40000 2143952       8
```

`marcxml_to_parquet()` does not return 2,143,952 rows to R. It returns only the
one-row conversion summary. Complete records are streamed from XML, parsed in
bounded batches, and written as independent Parquet parts. The number of parts
depends on `workers`, `batch_records`, and `chunk_records`; it is not a data
invariant.

Use `workers = 1L` for sequential execution. Parallel workers can improve
throughput, but they also increase concurrent memory use and should be
benchmarked on representative files.

### Open and query the Parquet dataset lazily

[Arrow Datasets](https://arrow.apache.org/docs/r/articles/dataset.html) let R
query a directory of Parquet files using familiar `dplyr` syntax. Opening the
dataset reads enough metadata to discover its schema; it does not construct a
2.1-million-row tibble:

```r
gpo <- arrow::open_dataset(gpo_parquet)

names(gpo)
#>  [1] "record_id"           "field_type"          "tag"
#>  [4] "subfield_code"       "value"               "field_order"
#>  [7] "field_occurrence"    "ind1"                "ind2"
#> [10] "subfield_order"      "subfield_occurrence"
```

Build a query before calling `collect()`. In this example Arrow performs the
aggregation against the dataset and only three result rows are brought into R:

```r
field_type_counts <- gpo |>
  dplyr::count(field_type, name = "rows") |>
  dplyr::arrange(field_type) |>
  dplyr::collect()

field_type_counts
#> # A tibble: 3 × 2
#>   field_type       rows
#>   <chr>            <int>
#> 1 controlfield    156999
#> 2 datafield      1946953
#> 3 leader           40000
```

A small set of titles can likewise be selected without collecting the full
canonical table:

```r
sample_titles <- gpo |>
  dplyr::filter(
    record_id <= 10L,
    tag == "245",
    subfield_code == "a"
  ) |>
  dplyr::select(record_id, title = value) |>
  dplyr::collect()

sample_titles
```

Do not call `collect()` directly on the complete dataset unless the result is
known to fit in memory. See Arrow's documentation for
[`open_dataset()`](https://arrow.apache.org/docs/r/reference/open_dataset.html)
and its guide to
[working with multi-file datasets](https://arrow.apache.org/docs/r/articles/dataset.html).

## Optional parallel parsing

Both public functions default to `workers = 1L`. To opt into local parallel
parsing:

```r
workers <- max(
  1L,
  as.integer(future::availableCores()) - 1L
)

parallel_result <- read_marcxml(
  example_file,
  workers = workers
)

identical(parallel_result, example)
#> [1] TRUE
```

Records are serialized before dispatch so XML external pointers are not passed
between processes. `mori` exposes the record strings through shared memory,
and `futurize` dispatches the `purrr` work through a temporary
`future.mirai` plan. The caller's previous future plan is restored afterward.

Parallelism is not assumed to be faster. XML reading, serialization, task
startup, parsing, and Parquet writing have different costs. Benchmark both
modes on the relevant machine and input.

## Canonical data model

Every result has these columns in this order:

| Column | Type | Meaning |
|---|---|---|
| `record_id` | integer | Sequential identity assigned during parsing; distinct from MARC control field `001` |
| `field_type` | character | `leader`, `controlfield`, or `datafield` |
| `tag` | character | `LDR` for the leader, otherwise the MARC field tag |
| `subfield_code` | character | Subfield code; `NA` for leaders and control fields |
| `value` | character | Textual content, without trimming meaningful whitespace |
| `field_order` | integer | Position in the source record; the leader is zero |
| `field_occurrence` | integer | Occurrence of the same field type and tag within the record |
| `ind1` | character | First data-field indicator; otherwise `NA` |
| `ind2` | character | Second data-field indicator; otherwise `NA` |
| `subfield_order` | integer | Position within the containing data field; otherwise `NA` |
| `subfield_occurrence` | integer | Occurrence of the same subfield code within that data field; otherwise `NA` |

This representation makes repetition and order explicit. It can later be
reshaped for a particular analysis, but the parser itself does not guess how
repeated values should be combined.

## Memory model and failure safety

The two workflows have different memory guarantees:

| Function | XML ingestion | Parsed result |
|---|---|---|
| `read_marcxml()` | Builds the complete XML tree | Returns the complete tibble in memory |
| `marcxml_to_parquet()` | Streams complete records and buffers at most one configured batch under normal operation | Writes task results to disk and returns only a summary |

Bounded memory is not constant memory. An unusually large individual MARC
record must still fit in memory, and parallel workers increase the amount of
work held concurrently.

Parquet files are first written under a staging directory beside the requested
output. The completed directory is published only after the entire conversion
succeeds. Existing output is not silently replaced.

## Scope of version 0.1.0

Version 0.1.0 focuses on faithful MARCXML ingestion. It does not:

- validate every record against the MARCXML XSD or MARC content rules;
- parse MARC ISO 2709 files;
- interpret the domain meaning of every MARC tag;
- silently deduplicate or collapse repeated fields or subfields;
- impose an application-specific wide representation; or
- attempt to replace an integrated library system.

## References

- Library of Congress, [MARC standards](https://www.loc.gov/marc/).
- Library of Congress, [MARC 21 FAQ](https://www.loc.gov/marc/faq.html).
- Library of Congress, [Understanding MARC Bibliographic](https://www.loc.gov/marc/umb/).
- Library of Congress, [MARCXML](https://www.loc.gov/standards/marcxml/).
- Library of Congress, [MARCXML uses and features](https://www.loc.gov/standards/marcxml/marcxml-overview.html).
- Library of Congress, [MARCXML design considerations](https://www.loc.gov/standards/marcxml/marcxml-design.html).
- Library of Congress, [MARCXML architecture](https://www.loc.gov/standards/marcxml/marcxml-architecture.html).
- U.S. Government Publishing Office, [All CGP Records (MARC XML)](https://github.com/usgpo/cataloging-records-all-cgp-marcxml).
- Apache Arrow for R, [Working with multi-file datasets](https://arrow.apache.org/docs/r/articles/dataset.html).
