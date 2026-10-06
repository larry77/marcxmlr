# marcxmlr

[![R-CMD-check](https://github.com/larry77/marcxmlr/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/larry77/marcxmlr/actions/workflows/R-CMD-check.yaml)
[![CRAN status](https://www.r-pkg.org/badges/version/marcxmlr)](https://CRAN.R-project.org/package=marcxmlr)

# MARC 21 and MARCXML

[MARC 21](https://www.loc.gov/marc/) stands for **Machine-Readable Cataloging**
and is a family of communication formats used to represent and exchange
bibliographic, authority, holdings, classification and community information.
The examples in this README use bibliographic MARC 21.

[MARCXML](https://www.loc.gov/standards/marcxml/) is the XML representation of
MARC 21. It expresses the same logical record structure through XML elements and
attributes rather than through the compact traditional MARC serialization.

`marcxmlr` is an R package for bringing MARCXML into ordinary analytical
workflows without first discarding the structure that makes MARC meaningful.
The central idea of the package is not simply XML parsing: it is a documented,
analyst-friendly rectangular representation of MARC structure.

# Installation

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

# How a MARC record is structured

A MARC record is not a conventional rectangular observation with one value for
each variable. It is an ordered structured record. In its traditional
machine-readable form, a record contains a **Leader**, a **Directory**, and an
ordered sequence of **variable fields**. The Directory is structural bookkeeping
for the compact MARC serialization: it records where the variable fields occur
in the record.

For analytical purposes, the important content-bearing structure is easier to
see by distinguishing three cases:

* a **Leader**, which occurs once at the beginning of the record;
* **control fields** such as `001` or `008`, which contain a value but no
  indicators or subfields; and
* **data fields** such as `100`, `245`, `264`, `650` or `856`, which contain a
  three-digit tag, two indicators, and an ordered sequence of coded subfields.

Both fields and subfields can repeat.

In conventional MARC notation, a title statement might look like:

```text
245 10 $a Nineteen eighty-four / $c George Orwell.
```

Here `245` is the field tag, `1` and `0` are the two indicators, `$a` contains
the main title information, and `$c` contains the statement of responsibility.
The meaning of a particular tag, indicator or subfield comes from MARC 21; for
example, the Library of Congress documents these definitions in the
[MARC 21 Format for Bibliographic Data](https://www.loc.gov/marc/bibliographic/).

The same field in MARCXML is:

```xml
<datafield tag="245" ind1="1" ind2="0">
  <subfield code="a">Nineteen eighty-four /</subfield>
  <subfield code="c">George Orwell.</subfield>
</datafield>
```

The XML hierarchy carries information that matters. The two `<subfield>`
elements are children of one particular `<datafield>` instance, and their order
is explicit. Repeated sibling `<datafield>` elements remain distinct even if
they have the same tag and indicators.

A subject field gives another example:

```xml
<datafield tag="650" ind1=" " ind2="0">
  <subfield code="a">Totalitarianism</subfield>
  <subfield code="v">Fiction.</subfield>
</datafield>
```

The blank first indicator is an actual MARC value. It is not missing data. A
representation that intends to preserve MARC faithfully has to distinguish that
blank from a case where indicators do not apply at all, as for a Leader or
control field.

# Why a simple flat table is not enough

A tempting analytical representation of a bibliographic record is one row per
record:

| record_id | title | author | subject |
|---:|---|---|---|
| 1 | Nineteen eighty four | George Orwell | Totalitarianism |

Such a table may be exactly what one particular analysis needs, but it is not a
general representation of the MARC record.

Consider two distinct subject fields:

```text
650 _0 $a Totalitarianism $v Fiction
650 _0 $a Dystopias $v Fiction
```

These are two different `650` field instances. Each `$v Fiction` belongs to one
particular occurrence of `650`.

If values are flattened independently by tag and subfield code, we might obtain:

```text
650$a = "Totalitarianism || Dystopias"
650$v = "Fiction || Fiction"
```

All values are still present, but field membership has disappeared. With more
heterogeneous repeated fields, the original associations cannot in general be
reconstructed unambiguously.

The same problem appears inside a single field when a subfield code repeats:

```text
856 40 $u https://example.org/1984 $y Full text $y Mirror
```

The two `$y` values are two ordered occurrences inside one specific `856` field.
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

This is the representational problem addressed by `marcxmlr`. The package does
not force MARC into a task-specific wide table during import. Instead, it first
creates a rectangular representation in which the original relationships remain
explicit. The analyst can then simplify that representation deliberately when
the purpose of the analysis is known.

# The canonical representation

The central idea of `marcxmlr` is a fixed **canonical representation** of MARC
content. It is a long rectangular table with exactly 11 columns. The hierarchy
has not disappeared: it has been translated into explicit coordinates.

The representation is designed to satisfy two goals at the same time:

1. **structural fidelity** — records, field instances, indicators, repeated
   fields, repeated subfields and source order remain distinguishable; and
2. **analytical usability** — the result is an ordinary R table that can be
   filtered, grouped, joined, reshaped and visualized with familiar tools.

This second point is important. The canonical table is not merely an internal
serialization format. It is intended to be pleasant to analyse. A librarian who
knows that the main title is in `245 $a`, for example, can ask for rows where the
tag is `245` and the subfield code is `a`; there is no need to formulate XPath
expressions or navigate XML nodes during analysis.

The canonical representation is therefore a **structural analytical layer**, not
a prescribed final table. One analysis may retain only titles and publishers,
another may study repeated subject headings, and another may select or edit
complete records before serializing them back to MARCXML.

## What one canonical row represents

The row meaning depends on the MARC structure being represented:

* the Leader contributes one row;
* each control field contributes one row; and
* each subfield occurrence of a data field contributes one row.

For a data field with several subfields, field-level information such as the tag,
indicators and field position is repeated on every row belonging to that field.
That repetition is deliberate. It lets each row carry enough context for direct
analysis while still making it possible to identify which rows belong to the
same field instance.

MARC tags remain **values** in the `tag` column rather than becoming columns of
their own. The schema therefore does not change when a catalogue contains an
unusual but structurally valid field. MARC knowledge determines what a field
means; the canonical representation determines how its structure is retained.

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

The columns are easier to understand as four related groups.

**Identity and structural kind.** `record_id` groups every canonical row produced
from the same MARC record. It is deliberately distinct from control field `001`,
which is source metadata and may be absent, nonnumeric or duplicated across
files. `field_type` distinguishes Leaders, control fields and data fields.

**MARC content.** `tag`, `subfield_code`, `value`, `ind1` and `ind2` carry the
content designation and values present in the source. For Leaders and control
fields, subfield and indicator columns are `NA` because those concepts do not
apply. A blank data-field indicator is instead preserved as the literal
one-character string `" "`.

**Structural coordinates.** `record_id`, `field_order` and `subfield_order` are
the principal coordinates of the hierarchy. Rows from the same data field share
the same `record_id` and `field_order`; `subfield_order` preserves the sequence
inside that field. These coordinates retain field membership and source order
and are the coordinates needed for faithful reconstruction.

**Analytical occurrence coordinates.** `field_occurrence` and
`subfield_occurrence` are derived conveniences for analysis. They number
repetition directly, making questions such as “the second `650` in this record”
or “the second `$y` in this `856`” easy to state. They are not the authoritative
source of serialization order; `field_order` and `subfield_order` already encode
that structure.

The small amount of redundancy is intentional. Repeating field context and
storing occurrence numbers makes the table easier to inspect, filter, group and
join. The package favours an explicit **analyst-friendly** representation over a
minimally encoded one.

## A complete example used throughout this README

The package bundles the following synthetic record as
`inst/extdata/orwell-marcxml.xml`. Every example below refers to this same record.

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

In canonical form, that one record becomes 16 rows and exactly 11 columns. For
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

Several features are visible directly:

* both `650` fields have the same tag but different `field_order` and
  `field_occurrence` values;
* the two rows of each `650` share the same `field_order`, so `$a` and `$v`
  remain attached to the correct field instance;
* the two `856 $y` values remain distinct, with `subfield_occurrence` values `1`
  and `2`;
* indicators remain attached to every row belonging to their data-field
  instance; and
* source order is retained at both field and subfield level.

## Why the representation is analyst-friendly

For someone who knows MARC 21, catalogue questions translate naturally into
conditions on documented columns. In plain language:

| Catalogue question | MARC designation | Condition on the canonical table |
|---|---|---|
| What is the main title? | `245 $a` | tag is `245` and subfield code is `a` |
| Which publisher is named in the publication statement? | `264 #1 $b` | tag is `264`, second indicator is `1`, and subfield code is `b` |
| Which is the second subject field? | second `650` | tag is `650` and field occurrence is `2` |
| Which is the second link label? | second `856 $y` | tag is `856`, subfield code is `y`, and subfield occurrence is `2` |

The package does not need to know that `245` is a title field or that
`264 #1 $b` identifies a publisher. That semantic knowledge comes from MARC 21.
`marcxmlr` provides a stable representation in which the corresponding
conditions can be expressed with ordinary tabular operations.

This is why the representation is deliberately richer than many final
analytical products. It preserves relationships before the analyst decides
which ones can safely be discarded. **Canonical to simplified is easy;
simplified to canonical may be impossible.**

## What semantic preservation means

`marcxmlr` preserves the represented MARC structure and values, not the
incidental byte-level serialization of the XML file. A read/write cycle can
preserve Leaders, control fields, data-field instances, indicators, subfields,
repetition, values and ordering without reproducing the same indentation,
namespace-prefix spelling, attribute order or other formatting details.

This preserve-first principle is the package's main design choice: field
membership, order or repetition discarded during import may be impossible to
reconstruct unambiguously afterward.

# Working with the same record in R

All examples below use the exact record shown above. It is bundled with the
package, so nothing needs to be downloaded.

```r
library(marcxmlr)
library(dplyr)

source_xml <- system.file(
  "extdata",
  "orwell-marcxml.xml",
  package = "marcxmlr"
)

marc <- read_marcxml(source_xml)

dim(marc)
#> [1] 16 11
```

The result is an ordinary tibble with the canonical columns described above.
Now the plain-language conditions can be translated directly into `dplyr`.

## What is the main title?

MARC 21 says that the main title is in `245 $a`: tag is `245` and subfield code
is `a`.

```r
marc |>
  filter(tag == "245", subfield_code == "a") |>
  select(record_id, value)
#> # A tibble: 1 × 2
#>   record_id value
#>       <int> <chr>
#> 1         1 Nineteen eighty-four /
```

## Which publisher is named in the publication statement?

For this record, `264 #1 $b` identifies the publisher: tag is `264`, the second
indicator is `1`, and the subfield code is `b`.

```r
marc |>
  filter(tag == "264", ind2 == "1", subfield_code == "b") |>
  select(record_id, value)
#> # A tibble: 1 × 2
#>   record_id value
#>       <int> <chr>
#> 1         1 Secker & Warburg,
```

The important transition is from a catalogue question, to its MARC content
designation, to ordinary table columns. XML traversal is no longer part of the
analysis.

## Which complete subject field contains `650 $a Totalitarianism`?

Sometimes the row that matches is not the whole answer. Here the question is
not only to find `$a Totalitarianism`, but to keep the complete `650` field to
which it belongs. Rows from one data-field instance share `record_id` and
`field_order`, so the field can be selected as a group:

```r
marc |>
  group_by(record_id, field_order) |>
  filter(
    any(
      tag == "650" &
        subfield_code == "a" &
        value == "Totalitarianism"
    )
  ) |>
  ungroup() |>
  select(record_id, field_order, tag, subfield_code, value)
#> # A tibble: 2 × 5
#>   record_id field_order tag   subfield_code value
#>       <int>       <int> <chr> <chr>         <chr>
#> 1         1           5 650   a             Totalitarianism
#> 2         1           5 650   v             Fiction.
```

The condition matches only `$a Totalitarianism`, but the result also contains
its associated `$v Fiction.` because both rows belong to the same field.

## Inspect repetition directly

The two subject fields remain separate:

```r
marc |>
  filter(tag == "650", subfield_code == "a") |>
  select(record_id, field_order, field_occurrence, value)
#> # A tibble: 2 × 4
#>   record_id field_order field_occurrence value
#>       <int>       <int>            <int> <chr>
#> 1         1           5                1 Totalitarianism
#> 2         1           6                2 Dystopias.
```

Repetition inside one field is equally explicit:

```r
marc |>
  filter(tag == "856") |>
  select(subfield_code, value, subfield_order, subfield_occurrence)
#> # A tibble: 3 × 4
#>   subfield_code value                    subfield_order subfield_occurrence
#>   <chr>         <chr>                             <int>               <int>
#> 1 u             https://example.org/1984              1                   1
#> 2 y             Full text                             2                   1
#> 3 y             Mirror                                3                   2
```

## Derive a simpler analytical table

The canonical representation preserves structure first. A simpler table can
then be derived deliberately for a particular analysis. For example, keep one
title and collapse each `650` field to a readable subject string:

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
#> # A tibble: 1 × 3
#>   record_id title                    subjects
#>       <int> <chr>                    <chr>
#> 1         1 Nineteen eighty-four /   Totalitarianism ; Fiction. | Dystopias. ; Fiction.
```

This is the intended asymmetry: once the MARC structure is preserved, it is easy
to collapse it for a particular purpose. Reconstructing field membership after
it has already been discarded may be impossible.

## Modify one repeated subfield

Because `subfield_occurrence` makes repetition explicit, a particular repeated
value can be changed without affecting its neighbour. Here only the second
`856 $y` changes:

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
  filter(tag == "856") |>
  select(subfield_code, value, subfield_occurrence)
#> # A tibble: 3 × 3
#>   subfield_code value                    subfield_occurrence
#>   <chr>         <chr>                                  <int>
#> 1 u             https://example.org/1984                   1
#> 2 y             Full text                                  1
#> 3 y             Backup access                              2
```

## Diagnose before writing

After filtering or editing canonical data, `diagnose_canonical()` can inspect
whether the representation still satisfies the structural contract required for
safe serialization.

```r
diagnostics <- diagnose_canonical(edited)
diagnostics
#> # A tibble: 0 × 6
#> # ℹ 6 variables: severity <chr>, code <chr>, message <chr>, record_id <int>,
#> #   field_order <int>, subfield_order <int>
```

An empty diagnostics tibble means that no structural issue was found. The
function checks the canonical representation used by `marcxmlr`; it is not a
complete MARC 21 content validator and does not replace MARCXML schema
validation.

`write_marcxml()` performs the required structural checks itself before writing.
Calling `diagnose_canonical()` explicitly is useful when data have been filtered
or edited because the result can be inspected before any XML file is created.

## Write MARCXML and read it back

A structurally coherent canonical table can be serialized again:

```r
out_xml <- tempfile(fileext = ".xml")
write_marcxml(edited, out_xml)

roundtrip <- read_marcxml(out_xml)
identical(edited, roundtrip)
#> [1] TRUE
```

The round trip preserves the MARC semantics represented by the canonical table,
not incidental XML formatting such as indentation or attribute order.

A complete record can likewise be selected and exported with ordinary table
operations before writing.

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
#> 1    16
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
