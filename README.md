# marcxmlr

[![R-CMD-check](https://github.com/larry77/marcxmlr/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/larry77/marcxmlr/actions/workflows/R-CMD-check.yaml)
[![CRAN status](https://www.r-pkg.org/badges/version/marcxmlr)](https://CRAN.R-project.org/package=marcxmlr)

`marcxmlr` brings MARC 21 data into ordinary R workflows without flattening
away the relationships that make MARC records meaningful.

MARC 21 records are commonly exchanged as MARCXML. The XML hierarchy preserves
records, field instances, indicators, subfields, repetition and source order,
but those relationships do not map directly to an ordinary rectangular data
frame. A simple wide conversion can keep the text while losing which subfields
belonged to which repeated field.

The central idea of `marcxmlr` is therefore **preserve first, simplify later**.
The package converts MARCXML to a fixed 11-column canonical representation in
which the MARC structure is explicit and can be queried with ordinary R tools.
A structurally coherent canonical table can also be written back to MARCXML.

The public API is intentionally small:

* `read_marcxml()` reads MARCXML into an in-memory tibble;
* `marcxml_to_parquet()` writes the same canonical representation to Parquet
  for larger, Arrow-backed workflows;
* `diagnose_canonical()` checks canonical data for structural problems relevant
  to serialization; and
* `write_marcxml()` writes structurally coherent canonical data back to
  MARCXML.

A typical in-memory workflow is:

```text
MARCXML
   ↓
read_marcxml()
   ↓
11-column canonical representation
   ↓
inspect / query / modify with ordinary R tools
   ↓
diagnose_canonical()
   ↓
write_marcxml()
   ↓
MARCXML
```

For larger collections, the same logical representation can remain on disk:

```text
MARCXML → marcxml_to_parquet() → Arrow / Parquet
```

This README is intended to be a self-contained introduction and tutorial. For a
shorter executable walkthrough, see the
[workflow vignette](vignettes/marcxmlr-workflow.Rmd). Readers interested in the
compiled parser, bounded-memory implementation, parallel execution and benchmark
methodology can continue with [Technical implementation and performance](TECHNICAL.md).

## Installation

Install the current CRAN release with:

```r
install.packages("marcxmlr")
```

To install the current development version from GitHub:

```r
# install.packages("pak")
pak::pak("larry77/marcxmlr")
```

Source installation from GitHub requires a C toolchain and libxml2 development
headers and libraries. On Debian and Ubuntu these are normally provided by
`r-base-dev` and `libxml2-dev`; Windows source builds use Rtools.

Both reading and writing support gzip-compressed MARCXML files such as
`catalogue.xml.gz`. `write_marcxml()` automatically produces gzip-compressed
output when the output filename ends in `.gz`.

# MARC 21, MARCXML and the tabular problem

Readers who already know MARC 21 can skim this section and continue with
[Why simple flattening loses information](#why-simple-flattening-loses-information)
or [The canonical representation](#the-canonical-representation).

## MARC 21 and MARCXML in brief

MARC stands for **Machine-Readable Cataloging**. MARC 21 is a family of
communication formats used to represent and exchange bibliographic, authority,
holdings, classification and community information in machine-readable form.
The examples below use bibliographic MARC 21.

A MARC record is not a conventional rectangular observation with one value for
each variable. It is an ordered structured record. A bibliographic record may
contain:

* a **Leader**;
* **control fields** such as `001` or `008`;
* **data fields** such as `100`, `245`, `264`, `650` or `856`;
* two **indicators** attached to each data field; and
* an ordered sequence of coded **subfields** within each data field.

Both fields and subfields can repeat.

In conventional MARC notation, a title statement might look like:

```text
245 10 $a Nineteen eighty-four / $c George Orwell.
```

Here `245` is the field tag, `1` and `0` are the two indicators, `$a` contains
the main title information and `$c` the statement of responsibility.

MARCXML is the Library of Congress XML representation of MARC. The same field
can be represented as:

```xml
<datafield tag="245" ind1="1" ind2="0">
  <subfield code="a">Nineteen eighty-four /</subfield>
  <subfield code="c">George Orwell.</subfield>
</datafield>
```

The XML hierarchy is important. The two `<subfield>` elements are children of
one particular `<datafield>` instance, and their order is explicit.

A subject field provides another small example:

```xml
<datafield tag="650" ind1=" " ind2="0">
  <subfield code="a">Totalitarianism</subfield>
  <subfield code="v">Fiction.</subfield>
</datafield>
```

The blank first indicator is an actual MARC value. In `marcxmlr` it is preserved
as the one-character string `" "`, which is different from `NA`: `NA` means
that indicators do not apply, as for Leaders and control fields.

## Why simple flattening loses information

A tempting analytical representation of a bibliographic record is one row per
record:

| record_id | title | author | subject |
|---:|---|---|---|
| 1 | Nineteen eighty four | George Orwell | Totalitarianism |

Such a table may be useful for a particular analysis, but it is not a general
representation of the MARC record.

Consider two distinct subject fields:

```text
650 _0 $a Totalitarianism $v Fiction
650 _0 $a Politics $x Philosophy
```

The first associates `$a Totalitarianism` with `$v Fiction`. The second
associates `$a Politics` with `$x Philosophy`.

If values are flattened independently by tag and subfield code, we might obtain:

```text
650$a = "Totalitarianism || Politics"
650$v = "Fiction"
650$x = "Philosophy"
```

All values are still present, but one relationship has disappeared: it is no
longer possible to infer with certainty which `$v` or `$x` belonged to which
occurrence of field `650`.

The same issue appears inside a single field when a subfield code repeats:

```text
700 1_ $a Smith, John $e editor $e translator
```

The two `$e` values are two ordered occurrences of the same subfield code inside
one specific `700` field instance.

A faithful general representation therefore has to preserve several levels of
identity and order:

```text
record
  ↓
field instance
  ↓
field tag, indicators and field position
  ↓
ordered subfield instances
  ↓
subfield code, value, order and occurrence
```

This is why `marcxmlr` does not immediately turn one MARC record into one wide
row. The choice to discard structure should be made by the analyst after import,
not implicitly by the parser.

# The canonical representation

`marcxmlr` represents MARC content as a long rectangular table with exactly 11
columns. MARC tags remain values rather than becoming tag-specific columns, so
the same schema can represent ordinary and unusual MARC content without changing
shape.

## The 11 columns

Every canonical result contains these columns, in this order:

| Column | Type | Meaning |
|---|---|---|
| `record_id` | integer | Sequential identity assigned by `marcxmlr`; distinct from MARC control field `001`. |
| `field_type` | character | `leader`, `controlfield`, or `datafield`. |
| `tag` | character | `LDR` for the Leader, otherwise the MARC field tag. |
| `subfield_code` | character | MARC subfield code; `NA` for Leaders and control fields. |
| `value` | character | Textual value, preserving meaningful source content. |
| `field_order` | integer | Position of the field instance in the source record; the Leader is `0`. |
| `field_occurrence` | integer | Occurrence number of the same field type and tag within the record. |
| `ind1` | character | First data-field indicator; may be `" "` when blank; otherwise `NA` when not applicable. |
| `ind2` | character | Second data-field indicator; may be `" "` when blank; otherwise `NA` when not applicable. |
| `subfield_order` | integer | Position of the subfield inside its containing data field; otherwise `NA`. |
| `subfield_occurrence` | integer | Occurrence number of that subfield code inside that particular field instance; otherwise `NA`. |

A Leader or control field contributes one canonical row. A data field contributes
one row for each subfield occurrence, with field-level information repeated on
every row belonging to that field.

## A complete structural example

Consider this synthetic MARCXML record:

```xml
<record xmlns="http://www.loc.gov/MARC21/slim">
  <leader>00000cam a2200000 i 4500</leader>
  <controlfield tag="001">12345</controlfield>

  <datafield tag="100" ind1="1" ind2=" ">
    <subfield code="a">Orwell, George,</subfield>
    <subfield code="d">1903-1950.</subfield>
  </datafield>

  <datafield tag="245" ind1="1" ind2="0">
    <subfield code="a">Nineteen eighty-four /</subfield>
    <subfield code="c">George Orwell.</subfield>
  </datafield>

  <datafield tag="264" ind1=" " ind2="1">
    <subfield code="a">London :</subfield>
    <subfield code="b">Secker &amp; Warburg,</subfield>
    <subfield code="c">1949.</subfield>
  </datafield>

  <datafield tag="650" ind1=" " ind2="0">
    <subfield code="a">Totalitarianism</subfield>
    <subfield code="v">Fiction.</subfield>
  </datafield>

  <datafield tag="650" ind1=" " ind2="0">
    <subfield code="a">Dystopias.</subfield>
    <subfield code="v">Fiction.</subfield>
  </datafield>

  <datafield tag="856" ind1="4" ind2="0">
    <subfield code="u">https://example.org/1984</subfield>
    <subfield code="y">Full text</subfield>
    <subfield code="y">Mirror</subfield>
  </datafield>
</record>
```

In canonical form, the structurally important repetitions remain explicit. For
readability, `<blank>` below denotes the actual one-character indicator value
`" "`:

| record_id | field_type | tag | subfield_code | value | field_order | field_occurrence | ind1 | ind2 | subfield_order | subfield_occurrence |
|---:|---|---|---|---|---:|---:|---|---|---:|---:|
| 1 | leader | LDR | NA | 00000cam a2200000 i 4500 | 0 | 1 | NA | NA | NA | NA |
| 1 | controlfield | 001 | NA | 12345 | 1 | 1 | NA | NA | NA | NA |
| 1 | datafield | 100 | a | Orwell, George, | 2 | 1 | 1 | `<blank>` | 1 | 1 |
| 1 | datafield | 100 | d | 1903-1950. | 2 | 1 | 1 | `<blank>` | 2 | 1 |
| 1 | datafield | 245 | a | Nineteen eighty-four / | 3 | 1 | 1 | 0 | 1 | 1 |
| 1 | datafield | 245 | c | George Orwell. | 3 | 1 | 1 | 0 | 2 | 1 |
| 1 | datafield | 264 | a | London : | 4 | 1 | `<blank>` | 1 | 1 | 1 |
| 1 | datafield | 264 | b | Secker & Warburg, | 4 | 1 | `<blank>` | 1 | 2 | 1 |
| 1 | datafield | 264 | c | 1949. | 4 | 1 | `<blank>` | 1 | 3 | 1 |
| 1 | datafield | 650 | a | Totalitarianism | 5 | 1 | `<blank>` | 0 | 1 | 1 |
| 1 | datafield | 650 | v | Fiction. | 5 | 1 | `<blank>` | 0 | 2 | 1 |
| 1 | datafield | 650 | a | Dystopias. | 6 | 2 | `<blank>` | 0 | 1 | 1 |
| 1 | datafield | 650 | v | Fiction. | 6 | 2 | `<blank>` | 0 | 2 | 1 |
| 1 | datafield | 856 | u | https://example.org/1984 | 7 | 1 | 4 | 0 | 1 | 1 |
| 1 | datafield | 856 | y | Full text | 7 | 1 | 4 | 0 | 2 | 1 |
| 1 | datafield | 856 | y | Mirror | 7 | 1 | 4 | 0 | 3 | 2 |

Several points are visible directly:

* both `650` fields have the same tag but different `field_order` and
  `field_occurrence` values;
* the subfields belonging to each `650` remain attached to the correct field
  because their rows share the same `record_id` and `field_order`;
* the two `856$y` values remain distinct, with `subfield_occurrence` values `1`
  and `2`;
* indicators remain attached to every row belonging to their data-field
  instance; and
* source order is retained at both field and subfield level.

## Structural coordinates and occurrence coordinates

The 11 columns deliberately contain a small amount of redundancy.

`record_id`, `field_order` and `subfield_order` are the principal structural
coordinates. For a data field, rows sharing the same `record_id` and
`field_order` belong to the same MARC field instance, while `subfield_order`
preserves the sequence inside that field.

`field_occurrence` and `subfield_occurrence` are **derived analytical
coordinates**. They are not the authoritative source of serialization order,
but they make repeated MARC content easier to address. They let ordinary R code
refer directly to, for example, the second `650` in a record or the second `$y`
inside one particular `856`.

This distinction matters when canonical data are modified. Structural order is
governed by `field_order` and `subfield_order`; occurrence columns can sometimes
be stale or renumberable without making the represented MARC structure
ambiguous.

## What semantic preservation means

`marcxmlr` preserves the represented MARC structure and values, not the
incidental byte-level serialization of the XML file. A read/write cycle can
preserve Leaders, control fields, data-field instances, indicators, subfields,
repetition, values and ordering without reproducing the same indentation,
namespace-prefix spelling, attribute order or other formatting details.

This is the package's main design choice: a simpler analytical view can always
be derived later when the intended analysis is known, while field membership,
order or repetition discarded during import may be impossible to reconstruct
unambiguously.

# Working with MARCXML in R

The package includes a small MARCXML collection, so all examples in this section
run without downloading external data.

```r
library(marcxmlr)
library(dplyr)

source_xml <- system.file(
  "extdata",
  "example-marcxml.xml",
  package = "marcxmlr"
)

marc <- read_marcxml(source_xml)

dim(marc)
#> [1] 18 11
```

The result is an ordinary tibble with the canonical columns described above.

## Inspect repeated structure

The first record contains one `856` field with two `$y` subfields:

```r
marc |>
  filter(record_id == 1L, tag == "856") |>
  select(
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

The same record contains two `650` fields. Their occurrences remain distinct:

```r
marc |>
  filter(record_id == 1L, tag == "650", subfield_code == "a") |>
  select(record_id, field_order, field_occurrence, value)
#> # A tibble: 2 × 4
#>   record_id field_order field_occurrence value
#>       <int>       <int>            <int> <chr>
#> 1         1           4                1 Libraries
#> 2         1           5                2 Metadata
```

## Query canonical data with `dplyr`

Because the canonical representation is an ordinary tibble, no special query
language is required. Title fields can be selected directly by MARC tag:

```r
marc |>
  filter(tag == "245") |>
  select(record_id, subfield_code, value)
#> # A tibble: 3 × 3
#>   record_id subfield_code value
#>       <int> <chr>         <chr>
#> 1         1 a             Scalable catalogues :
#> 2         1 b             a synthetic example
#> 3         2 a             Café metadata & reproducible examples
```

MARC knowledge still determines which content designation answers a particular
catalogue question; `marcxmlr` makes that designation directly expressible as
conditions on table columns.

A condition can also select a **complete field instance**, rather than only the
row that matched. Grouping by `record_id` and `field_order` preserves field
membership:

```r
marc |>
  group_by(record_id, field_order) |>
  filter(
    any(
      tag == "650" &
        subfield_code == "a" &
        value == "Libraries"
    )
  ) |>
  ungroup() |>
  select(record_id, field_order, tag, subfield_code, value)
#> # A tibble: 2 × 5
#>   record_id field_order tag   subfield_code value
#>       <int>       <int> <chr> <chr>         <chr>
#> 1         1           4 650   a             Libraries
#> 2         1           4 650   x             Data processing
```

The condition matches only `650$a Libraries`, but the associated `$x Data
processing` remains in the result because both rows belong to the same field
instance.

## Derive a simpler analytical table

The canonical representation is designed to preserve structure first. Once the
purpose of an analysis is known, a simpler table can be derived deliberately.
For example:

```r
titles <- marc |>
  filter(tag == "245", subfield_code == "a") |>
  transmute(record_id, title = value)

subjects <- marc |>
  filter(tag == "650") |>
  group_by(record_id, field_order) |>
  summarise(
    subject = paste(value, collapse = " ; "),
    .groups = "drop"
  ) |>
  group_by(record_id) |>
  summarise(
    subjects = paste(subject, collapse = " | "),
    .groups = "drop"
  )

left_join(titles, subjects, by = "record_id")
```

This transformation is intentionally one-way. Collapsing canonical data is easy
once the analytical purpose is known; reconstructing field membership and order
from an already simplified table may be impossible.

## Modify repeated MARC data

A specific repeated value can be addressed through the occurrence coordinates.
Here only the second `856$y` value in record 1 is changed:

```r
edited <- marc |>
  mutate(
    value = if_else(
      record_id == 1L &
        tag == "856" &
        subfield_code == "y" &
        subfield_occurrence == 2L,
      "Backup access",
      value
    )
  )

edited |>
  filter(record_id == 1L, tag == "856") |>
  select(subfield_code, value, subfield_occurrence)
#> # A tibble: 3 × 3
#>   subfield_code value                      subfield_occurrence
#>   <chr>         <chr>                                    <int>
#> 1 u             https://example.org/item/1                   1
#> 2 y             Full text                                    1
#> 3 y             Backup access                                2
```

## Diagnose before writing

After filtering or modification, `diagnose_canonical()` can be used as an
explicit structural preflight:

```r
diagnostics <- diagnose_canonical(edited)
diagnostics
#> # A tibble: 0 × 6
#> # ℹ 6 variables: severity <chr>, code <chr>, message <chr>, record_id <int>,
#> #   field_order <int>, subfield_order <int>
```

A zero-row diagnostics tibble means that no structural issue was found. When
diagnostics are present, each row reports a severity, a diagnostic code, a
human-readable message and the relevant record or position when available.

An `error` identifies a structural problem that prevents safe serialization. A
`warning` identifies something that deserves attention but does not make the
represented MARC structure ambiguous. For example, occurrence coordinates may
be stale or renumberable even when the structural ordering remains clear.

`diagnose_canonical()` checks the structural contract required by `marcxmlr`.
It is not a complete MARC 21 content validator and does not replace MARCXML
schema validation.

## Write MARCXML and read it back

`write_marcxml()` serializes coherent canonical data back to MARCXML. The writer
performs the required structural checks before writing.

```r
out_xml <- tempfile(fileext = ".xml")
write_marcxml(edited, out_xml)

roundtrip <- read_marcxml(out_xml)
identical(edited, roundtrip)
#> [1] TRUE
```

A useful related workflow is to select complete records and export them:

```r
selected <- marc |>
  filter(record_id == 1L)

selected_xml <- tempfile(fileext = ".xml")
write_marcxml(selected, selected_xml)

identical(selected, read_marcxml(selected_xml))
#> [1] TRUE
```

The selection or modification happens with ordinary R tools, while the output
is again MARCXML that can be exchanged with software outside R.

# Large collections and Parquet

Both the in-memory and Parquet workflows use the same 11-column canonical
representation. The practical difference is where that representation lives.

Use `read_marcxml()` when the source and expanded canonical result fit
comfortably in memory. The `n_max` argument can restrict parsing to the first
records, which is useful for previews and development:

```r
preview <- read_marcxml(
  source_xml,
  n_max = 1L
)

unique(preview$record_id)
#> [1] 1
```

For larger collections, materializing all canonical rows as one R object may be
unnecessary. `marcxml_to_parquet()` writes the same schema to a directory of
Parquet files while keeping the expanded canonical data bounded by processing
batches.

Arrow support is optional. Install it when needed:

```r
install.packages("arrow")
```

The bundled example can be converted to Parquet with:

```r
parquet_dir <- tempfile()

marcxml_to_parquet(
  source_xml,
  output_dir = parquet_dir,
  workers = 1L,
  verbose = FALSE
)

catalogue <- arrow::open_dataset(parquet_dir)

catalogue |>
  summarise(rows = n()) |>
  collect()
#> # A tibble: 1 × 1
#>    rows
#>   <int>
#> 1    18
```

The dataset can be filtered and aggregated with Arrow and `dplyr` before a
smaller result is collected into R:

```r
catalogue |>
  filter(tag == "650", subfield_code == "a") |>
  count(value, sort = TRUE) |>
  collect()
```

For a catalogue already split across several files:

```r
files <- sort(Sys.glob("data/catalogue/*.xml"))

marcxml_to_parquet(
  files,
  output_dir = "catalogue_parquet",
  workers = 4L
)
```

When several input files are converted together, `record_id` values are assigned
in deterministic input-file order and remain globally contiguous across the
logical dataset.

For one MARCXML file, the optimized sequential path is the natural starting
point and additional worker processes may be slower. Parallel execution is more
naturally useful when substantial independent files can be assigned to separate
workers.

## How the two storage workflows are implemented

The in-memory and Parquet workflows use the same logical representation and, for
supported ordinary MARCXML, the same package-specific compiled parser. The
important difference is how much of the expanded canonical representation is
materialized at one time.

The optimized sequential parser is implemented in C on top of `libxml2` and
uses two passes over the input. The first pass determines how many canonical rows
each selected record will produce. The second pass allocates the required output
vectors at their final size and fills them directly while traversing the MARC
structure in source order.

For `read_marcxml()`, the second pass materializes the complete selected result
as one tibble. For `marcxml_to_parquet()`, successive groups of complete records
are materialized and written as Parquet parts, so the complete expanded table
does not have to exist as one R object. The record remains the natural processing
unit because its Leader, fields and subfields must remain structurally coherent.

The same principle applies in the other direction. `write_marcxml()` can write
an in-memory canonical table directly, while Arrow-backed canonical data can be
scanned incrementally without first collecting the complete Dataset into one
R tibble. Structural relationships are reconstructed from `record_id`,
`field_order` and `subfield_order`; the occurrence columns remain analytical
coordinates rather than the authoritative source of serialization order.

Readers who want the lower-level details of the `libxml2` reader/writer,
two-pass allocation, bounded Arrow scans and retained reference implementations
can continue with [Technical implementation and performance](TECHNICAL.md).

## Parallel execution in practice

`workers = 1L` is the default and should normally be the starting point for a
single MARCXML file. With one file, requesting multiple workers requires a
worker-safe record-based execution path and adds process creation, task
coordination and data-transfer overhead. Once the sequential parser itself is
fast, those costs can outweigh the available parallel work.

A catalogue already divided into several substantial MARCXML files is a more
natural parallel workload. Complete files can be assigned to separate workers,
while each worker retains the optimized sequential parser internally. Before
multi-file conversion begins, `marcxmlr` assigns deterministic, non-overlapping
`record_id` ranges from input-file order, so worker completion order does not
change the logical record identities in the resulting Dataset.

This is a practical recommendation rather than a universal threshold: CPU,
memory, storage, compression, file layout and record complexity all matter.
Benchmark representative input before relying on additional workers.

## Performance scale for version 0.3.1

The following measurements are included to indicate scale, not to promise
performance on other systems. They were obtained with `marcxmlr` 0.3.1 on a
Lenovo ThinkPad P50 with an Intel Core i7-6820HQ, 31.18 GiB RAM and a local SSD,
using R 4.6.1 and Arrow 25.0.1.

| Workflow | Input | Median elapsed time |
|---|---:|---:|
| `read_marcxml()` | 40,000 records / 2,143,952 rows | 7.106 s |
| `marcxml_to_parquet()`, 1 worker | 40,000 records / 2,143,952 rows | 9.374 s |
| `write_marcxml()` from Arrow | 40,000 records / 2,143,952 rows | 14.493 s |
| `marcxml_to_parquet()`, 4 workers | 27 files / 1,080,000 records / 67,672,396 rows | 118.629 s |

The single-file parallel measurements are also a useful warning against assuming
that more workers are automatically faster: the same 40,000-record Parquet
conversion took 19.858 s with two workers and 18.849 s with four, compared with
9.374 s sequentially. Across the 27-file corpus, by contrast, four workers
reduced elapsed time from 290.139 s to 118.629 s.

Detailed benchmark methodology, memory measurements and implementation context
are provided in [Technical implementation and performance](TECHNICAL.md).

# Scope and further documentation

`marcxmlr` deliberately separates faithful structural representation from later
interpretation. It does **not** attempt to:

* repair cataloguing records;
* infer missing fields or subfields;
* normalize different cataloguing practices;
* collapse repeated values on behalf of the analyst;
* automatically map a catalogue to another metadata model; or
* replace complete MARC 21 content or MARCXML schema validation.

Its job is narrower: represent supported MARCXML faithfully enough that later
selection, reshaping, validation, mapping and analysis are explicit choices made
with ordinary R tools.

For further reading:

* [Workflow vignette](vignettes/marcxmlr-workflow.Rmd) — a shorter executable
  read → inspect/query → diagnose → write → Parquet walkthrough. After installing
  a package build that includes the vignette, it can also be opened with
  `browseVignettes("marcxmlr")`.
* [Technical implementation and performance](TECHNICAL.md) — optional deeper
  reading on compiled parsing, bounded-memory processing, Arrow-backed writing,
  parallel execution, validation internals and benchmark methodology.

The README and vignette are intended to be sufficient for using the package.
The technical note is supplementary material for readers who want to understand
how the computational paths are implemented and evaluated.

The implementation principle is the same throughout: **preserve the MARC
structure first, then simplify or optimize without changing the logical data
model**.
