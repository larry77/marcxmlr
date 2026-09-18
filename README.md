# marcxmlr

[![R-CMD-check](https://github.com/larry77/marcxmlr/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/larry77/marcxmlr/actions/workflows/R-CMD-check.yaml)
[![CRAN status](https://www.r-pkg.org/badges/version/marcxmlr)](https://CRAN.R-project.org/package=marcxmlr)

`marcxmlr` provides faithful, tidy and scalable parsing of MARC 21 XML in R.

It preserves repeated fields, repeated subfields, indicators and source order in
one canonical 11-column long representation. The same representation is used
whether records are read into memory or converted in bounded batches to an
Apache Parquet dataset.

Version 0.2.0 substantially changes the implementation underneath that stable
representation. The main parsing paths now use compiled C code and libxml2
directly, avoiding several expensive layers of XML serialization, reparsing,
R-level traversal and repeated allocation.

The package has two public entry points:

* `read_marcxml()` parses MARCXML into an in-memory tibble.
* `marcxml_to_parquet()` converts one or many MARCXML collections to a
  bounded-memory Parquet dataset.

For a **single MARCXML file**, start with `workers = 1`. The optimized native
sequential engine is now fast enough that process startup and coordination can
cost more than they save. Parallelism is much more useful when a catalogue is
naturally split across **multiple XML files**: `marcxml_to_parquet()` can process
complete files concurrently while preserving deterministic global record
identifiers.

## Installation

Install the version currently available from CRAN with:

```r
install.packages("marcxmlr")
```

Install the current GitHub version with:

```r
install.packages("remotes")
remotes::install_github("larry77/marcxmlr")
```

Version 0.2.0 contains compiled C code. Building from source requires a C
toolchain and libxml2 development headers/libraries. On Debian and Ubuntu these
are normally provided by `r-base-dev` and `libxml2-dev`; Fedora/RHEL use
`libxml2-devel`. Windows source builds use Rtools.

The examples below use `dplyr`, and the bounded Parquet workflow additionally
uses `XML` and `arrow`:

```r
install.packages(c("dplyr", "XML", "arrow"))
```

Optional parallel execution uses:

```r
install.packages(
  c("future", "future.mirai", "futurize", "furrr", "mori")
)
```

The sequential core supports R 4.1 and later. With current dependency versions,
the optional parallel machinery requires a newer R installation.

## What are MARC 21 and MARCXML?

[MARC 21](https://www.loc.gov/marc/) is a family of formats for representing
and exchanging bibliographic and related metadata. A MARC record is ordered
and hierarchical: it contains a leader, control fields and data fields. Data
fields have two indicators and one or more coded subfields.

Fields can repeat. Subfields can repeat. Their order can matter. A representation
that simply collapses every occurrence of, for example, `650$a` or `856$u`
cannot always reconstruct which values belonged to which original field.

[MARCXML](https://www.loc.gov/standards/marcxml/) is the Library of Congress XML
representation of MARC 21. Tags and indicators are encoded as attributes and
subfields as child elements while the MARC record structure is retained.

`marcxmlr` is deliberately narrower than a catalogue system or a general XML
framework. Its job is to move MARCXML into an analysis-friendly representation
without silently discarding that structure.

## Why version 0.2.0 is much faster

The canonical table itself has not changed. The expensive machinery used to
produce it has.

The main bottlenecks addressed during the 0.2.0 development cycle were:

1. serializing complete `<record>` elements back to XML text and reparsing them;
2. repeated XML-tree and XPath traversal from R;
3. repeated allocation and growth of intermediate R objects;
4. repeated higher-level work to calculate field and subfield occurrences; and
5. worker/process overhead in cases where the parser itself had already become
   very fast.

The optimized native paths move this work closer to libxml2:

* records are traversed directly from libxml2 nodes in compiled C code;
* output vectors are preallocated and filled directly;
* field and subfield occurrence counts use native hashed bookkeeping;
* the sequential reader uses a validation/counting pass followed by direct
  construction of the canonical result;
* the Parquet converter uses a bounded native streaming path and fills canonical
  batches directly before writing them with Arrow.

The previous R/XML implementations remain available as compatibility fallbacks
for inputs that the conservative native paths decline. XML/libxml2 external
pointers are never passed between parallel workers.

The result is not a different MARC representation. It is a substantially faster
way of producing the same one.

## A small real-world example

The Library of Congress publishes a MARCXML record for Carl Sandburg's
*Arithmetic*:

```bash
mkdir -p data/loc

curl --fail --location \
  "https://www.loc.gov/standards/marcxml/Sandburg/sandburg.xml" \
  --output data/loc/sandburg.xml
```

Read it into R:

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
```

The package also installs a small synthetic collection used in examples and
tests:

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

Repeated subfields remain separate:

```r
example |>
  dplyr::filter(record_id == 1L, tag == "856") |>
  dplyr::select(
    subfield_code,
    value,
    subfield_order,
    subfield_occurrence
  )
```

On the optimized sequential native path, `read_marcxml()` does **not** build a
DOM for the complete collection. It validates/counts the selected records and
then fills the canonical output directly. Compatibility fallbacks may use a
different XML representation. The complete resulting tibble is, however, still
materialized in R memory.

## The canonical 11-column representation

### Why not reproduce the familiar MARC field display?

MARC 21 is highly structured and is often displayed in a form that looks
tabular, with one field per line. Part of the first record in the bundled
example could be written in the familiar form:

```text
245 10 $a Scalable catalogues : $b a synthetic example
650 #0 $a Libraries $x Data processing
650 #0 $a Metadata
856 40 $u https://example.org/item/1 $y Full text $y Alternate access
```

Here `#` is a conventional display symbol for a blank indicator. It is not the
character stored in the MARCXML record.

This display is a useful view of a record, but it is not one rectangular data
table. Records contain repeatable fields, while data fields contain their own
repeatable subfields. A table with one row per field would therefore have to
store the subfields in a combined string or a list-column. A table with one
row per record would need list-columns, numbered columns, or rules for joining
repeated values. Those choices make filtering, counting, SQL queries, and
Arrow processing more difficult, and combined strings must later be parsed
again.

`marcxmlr` instead represents the smallest content-bearing MARC units:

- a leader occupies one row;
- a control field occupies one row; and
- each subfield of a data field occupies one row.

The tag, indicators, and identity of a data field are repeated on each of its
subfield rows. This small amount of deliberate redundancy produces one stable
table while preserving which subfields belong to the same field. A familiar
one-row-per-field display can always be derived from it.

### Column definitions

Every result has the following columns, in this order:

| Column | Type | Precise meaning |
|---|---|---|
| `record_id` | integer | Positive identity assigned to each record during parsing. It is stable across sequential and parallel execution and is not taken from control field `001`. The original `001`, when present, remains a control-field row. |
| `field_type` | character | The structural kind of the source element: `leader`, `controlfield`, or `datafield`. |
| `tag` | character | `LDR` for the leader; otherwise the MARC field tag such as `001`, `245`, or `856`. It is character data so leading zeros are preserved. |
| `subfield_code` | character | The code of a data-field subfield, such as `a`, `x`, `u`, or `2`. It is `NA` for leaders and control fields, which do not contain subfields. |
| `value` | character | The leader value, complete control-field value, or individual subfield value. Values are not converted to numbers or dates, and meaningful leading or trailing whitespace is not trimmed. |
| `field_order` | integer | Identity and source position of a field inside its record. The leader is `0`; variable fields are numbered `1, 2, ...`. All subfield rows belonging to one data field have the same `field_order`. Even when source order is not analytically important, this column is the unambiguous field-instance key. |
| `field_occurrence` | integer | One-based occurrence of the same field type and tag inside a record. For example, two `650` fields have occurrences `1` and `2`. The value is repeated across all subfields of that field. |
| `ind1` | character | First indicator value of a data field, stored as character data, including a blank space. In conforming MARC 21 this is one character. It is `NA` for the leader and control fields because indicators do not apply to them. |
| `ind2` | character | Second indicator of a data field, with the same storage rules as `ind1`. Its interpretation, like that of `ind1`, depends on the field tag. |
| `subfield_order` | integer | One-based position of a subfield inside its containing data field. It is `NA` for leaders and control fields. |
| `subfield_occurrence` | integer | One-based occurrence of the same subfield code inside one data field. In the example `856`, the two `$y` subfields have occurrences `1` and `2`. It is `NA` for leaders and control fields. |

The keys needed to distinguish structural units are therefore:

- record: `record_id`;
- field: `record_id + field_order`; and
- subfield: `record_id + field_order + subfield_order`.

`field_occurrence` and `subfield_occurrence` are convenient, readable counters
within those units. They are particularly useful when selecting the first,
second, or subsequent occurrence of a tag or code.

### Indicators are part of the MARC meaning

`ind1` and `ind2` are character columns rather than numbers. A blank indicator
is stored as `" "`; it is different from `NA`, which means that indicators do
not apply to that row. Indicator meanings are defined separately for each MARC
field and should not be interpreted as a single scale.

For example, in the bundled record:

- `245 10` means that field `245` has first indicator `1` (a title added entry)
  and second indicator `0` (no initial characters are excluded for filing), as
  defined for the
  [MARC 21 title statement](https://www.loc.gov/marc/bibliographic/bd245.html);
- `856 40` means that field `856` uses HTTP (`ind1 = "4"`) and links to the
  resource described by the record (`ind2 = "0"`), as defined for
  [electronic location and access](https://www.loc.gov/marc/bibliographic/bd856.html).

Preserving indicators as data allows catalogue-wide questions such as which
title-filing conventions or electronic-resource relationships occur in the
source records.

### Why the long representation is convenient for analysis

The first example record has two separate `650` subject fields. The first has
subfields `$a` and `$x`; the second has another `$a`. Grouping by
`field_order` keeps these headings separate while making their content easy to
summarize:

```r
subjects <- example |>
  dplyr::filter(record_id == 1L, tag == "650") |>
  dplyr::arrange(field_order, subfield_order) |>
  dplyr::group_by(record_id, field_order, field_occurrence) |>
  dplyr::summarise(
    subject = paste(value, collapse = " -- "),
    .groups = "drop"
  )

subjects
#> # A tibble: 2 × 4
#>   record_id field_order field_occurrence subject
#>       <int>       <int>            <int> <chr>
#> 1         1           4                1 Libraries -- Data processing
#> 2         1           5                2 Metadata
```

Grouping only by `record_id` and `tag` would incorrectly merge both subject
fields. The field-instance key prevents that error without requiring nested
objects or parsing `$a` and `$x` out of a combined string.

Because one data field contributes one row per subfield, counting table rows
does not necessarily count fields. Actual field counts are obtained by first
selecting distinct field instances:

```r
field_counts <- example |>
  dplyr::filter(field_type == "datafield") |>
  dplyr::distinct(record_id, field_order, tag, ind1, ind2) |>
  dplyr::count(tag, name = "fields")

field_counts
#> # A tibble: 5 × 2
#>   tag   fields
#>   <chr>  <int>
#> 1 100        1
#> 2 245        2
#> 3 500        1
#> 4 650        2
#> 5 856        1
```

When the field-level MARC view is desirable, it can be recreated explicitly:

```r
marc_field_view <- example |>
  dplyr::filter(record_id == 1L, field_type == "datafield") |>
  dplyr::arrange(field_order, subfield_order) |>
  dplyr::group_by(record_id, field_order, tag, ind1, ind2) |>
  dplyr::summarise(
    contents = paste0(
      "$", subfield_code, " ", value,
      collapse = " "
    ),
    .groups = "drop"
  )

marc_field_view |>
  dplyr::filter(tag == "856")
#> # A tibble: 1 × 6
#>   record_id field_order tag   ind1  ind2  contents
#>       <int>       <int> <chr> <chr> <chr> <chr>
#> 1         1           6 856   4     0     $u https://example.org/item/1 ...
```

The traditional MARC-shaped table is therefore a view that can be derived for
display. The canonical long representation is retained underneath because it
is safer and more convenient for analytical work.

## Large real-world example: U.S. Government Publishing Office

The U.S. Government Publishing Office publishes the
[Catalog of U.S. Government Publications](https://catalog.gpo.gov/) as public
MARCXML. The February 2026 snapshot used during development was split across 28
ZIP files of roughly 40,000 records each.

GPO also documents validation problems in the source collection. This makes it
useful integration data: real catalogues are not necessarily perfectly clean.
`marcxmlr` is deliberately strict about malformed MARCXML structure and reports
the input file in which a multi-file conversion fails.

### One 40,000-record MARCXML file

For a single file, the recommended starting point in 0.2.0 is simply sequential
execution:

```r
library(marcxmlr)

gpo_xml <- paste0(
  "data/gpo/",
  "cataloging-records-all-cgp-XML-00.xml"
)

gpo_parquet <- "data/gpo/gpo-00-parquet"

conversion <- marcxml_to_parquet(
  gpo_xml,
  output_dir = gpo_parquet,
  batch_records = 5000L
)

conversion
```

For the February 2026 part `00` used during development, this produced:

```text
40,000 records
2,143,952 canonical rows
```

The full canonical result is not returned to R. `marcxml_to_parquet()` writes
bounded batches as Parquet fragments and returns a conversion summary.

The resulting directory can be queried lazily with Arrow:

```r
gpo <- arrow::open_dataset(gpo_parquet)

gpo |>
  dplyr::filter(
    record_id <= 10L,
    tag == "245",
    subfield_code == "a"
  ) |>
  dplyr::select(record_id, title = value) |>
  dplyr::collect()
```

Avoid calling `collect()` on an entire large dataset unless the result is known
to fit in memory.

### Multiple MARCXML files

Version 0.2.0 allows `marcxml_to_parquet()` to accept an explicit vector of files
or a glob pattern:

```r
conversion <- marcxml_to_parquet(
  "data/gpo/cataloging-records-all-cgp-XML-*.xml",
  output_dir = "data/gpo/gpo-multi-parquet",
  batch_records = 5000L,
  workers = 4L
)
```

Glob matches are resolved in sorted order. For multi-file input, complete files
are the unit of parallel work. Each worker internally uses the optimized
sequential parser.

`record_id` remains globally contiguous and deterministic across the entire
dataset. Worker completion order does not alter the canonical result.

This is the preferred use of parallelism in 0.2.0: parallelize **files**, rather
than automatically parallelizing the records inside one already-fast native
parse.

## Performance observed during development

The figures below are development measurements, not performance guarantees.
They depend on hardware, storage, XML structure, compression and package
versions.

On the development machine, one 40,000-record GPO file producing 2,143,952
canonical rows gave approximately:

| Operation | Execution | Elapsed time |
| --- | --- | ---: |
| `read_marcxml()` | direct native sequential | 6.5 s |
| `marcxml_to_parquet()` | native sequential, 5,000-record batches | 8.4 s |

The important practical change is that within-file parallelism is no longer the
obvious optimization. Once the parsing bottlenecks were moved into C/libxml2,
the overhead of splitting one XML file among processes can outweigh the parsing
work itself.

A larger multi-file development run used 27 GPO XML files. The final source
file in the downloaded snapshot was excluded from this benchmark because it
contained a malformed MARC data field with no subfield elements:

```text
1,080,000 records
67,672,396 canonical rows
216 Parquet files
```

Observed elapsed times were approximately:

| File-level workers | Elapsed time |
| ---: | ---: |
| 4 | 121.7 s |
| 7 | 99-100 s |

The 4-worker and 7-worker runs produced byte-identical Parquet fragments in that
test.

These results illustrate the intended performance model rather than promise a
specific speedup: use the optimized sequential engine for an individual file;
use file-level parallelism when a catalogue naturally consists of several
files.

## Parallelism

Both public functions still accept `workers`.

For both `read_marcxml()` and single-file `marcxml_to_parquet()`, `workers = 1L`
should normally be tried first. The older worker-safe serialized-record paths
are retained for compatibility and experimentation. For single-file
`marcxml_to_parquet()` calls, version 0.2.0 emits a periodic warning when
multiple workers are requested because parallel execution may be slower.

For multi-file `marcxml_to_parquet()` calls, `workers > 1L` means file-level
parallelism. This avoids making the fastest native single-file parser pay the
cost of unnecessary record-level process coordination.

The previous `future` plan is restored after package-managed parallel work.

## Memory model and failure safety

The two workflows deliberately have different memory contracts:

| Function | XML processing | Result |
| --- | --- | --- |
| `read_marcxml()` | Direct native parsing on the optimized path; compatibility fallback when needed | Complete canonical tibble in memory |
| `marcxml_to_parquet()` | Bounded native batches on the optimized path | Parquet dataset on disk plus a small summary |

Bounded memory does not mean constant memory. An unusually large individual
record must still fit in memory, and multiple file-level workers naturally
increase concurrent memory use.

Parquet output is written under a staging directory beside the requested
destination. The final dataset directory is published only after the complete
conversion succeeds. Existing output directories are not silently overwritten.

## Scope of version 0.2.0

Version 0.2.0 focuses on faithful and scalable MARCXML ingestion. It does not:

* validate every record against the complete MARCXML XSD or all MARC content
  rules;
* parse MARC ISO 2709 files;
* interpret the domain meaning of every MARC tag and indicator;
* silently deduplicate or collapse repeated fields or subfields;
* impose an application-specific wide representation; or
* attempt to replace an integrated library system.

The canonical representation is intentionally conservative: structural
information is preserved first, and application-specific analytical views can
be derived from it afterward.

## References

* Library of Congress, [MARC standards](https://www.loc.gov/marc/).
* Library of Congress, [MARCXML](https://www.loc.gov/standards/marcxml/).
* Library of Congress,
  [MARCXML design considerations](https://www.loc.gov/standards/marcxml/marcxml-design.html).
* U.S. Government Publishing Office,
  [All CGP Records (MARC XML)](https://github.com/usgpo/cataloging-records-all-cgp-marcxml).
* Apache Arrow for R,
  [Working with multi-file datasets](https://arrow.apache.org/docs/r/articles/dataset.html).
