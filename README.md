# marcxmlr

[![R-CMD-check](https://github.com/larry77/marcxmlr/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/larry77/marcxmlr/actions/workflows/R-CMD-check.yaml)
[![CRAN status](https://www.r-pkg.org/badges/version/marcxmlr)](https://CRAN.R-project.org/package=marcxmlr)

`marcxmlr` helps bring MARC 21 data into ordinary R data workflows.

MARC 21 records are commonly exchanged as MARCXML, whose hierarchical and
repetitive structure does not naturally fit the rectangular data model usually
used for analysis in R and the tidyverse.

`marcxmlr` converts MARCXML into a tidy representation that preserves MARC
structure, allowing the data to be inspected, selected and modified with
ordinary R tools. The resulting representation can also be written back to
MARCXML.

A typical workflow is therefore:

```text
MARCXML
   ↓
read_marcxml()
   ↓
tidy MARC representation in R
   ↓
inspect / select / modify with ordinary R tools
   ↓
write_marcxml()
   ↓
MARCXML
```

Part I explains why this representation is needed and how it preserves the
structure of MARC records.

## Installation

CRAN currently provides `marcxmlr` 0.2.1. That version predates MARCXML writing.

Install the CRAN version with:

```r
install.packages("marcxmlr")
```

To use `write_marcxml()` and the complete round trip workflow described in this
README, install the current GitHub version:

```r
# install.packages("pak")
pak::pak("larry77/marcxmlr")
```

Source installation from GitHub requires a C toolchain and libxml2 development
headers and libraries. On Debian and Ubuntu these are normally provided by
`r-base-dev` and `libxml2-dev`; Windows source builds use Rtools.

# Part I: Using and understanding `marcxmlr`

Part I explains the data model first and the R workflow second. Readers who
already know MARC 21 can skip [MARC 21 and MARCXML](#marc-21-and-marcxml) and
continue with [Why simple flattening loses information](#why-simple-flattening-loses-information).
The discussion of flattening and [the canonical representation](#the-canonical-representation)
is central to understanding the package.

## MARC 21, MARCXML and the tabular problem

### MARC 21 and MARCXML

MARC means **MAchine Readable Cataloging**. MARC 21 is a family of communication formats used to represent and exchange bibliographic, authority, holdings, classification, and community information in machine readable form.

A MARC record is not a conventional rectangular observation with one value for each variable. It is an ordered structured record. A bibliographic record may contain:

* a leader;
* control fields such as `001` or `008`;
* data fields such as `100`, `245`, `264`, `650`, or `856`;
* two indicators attached to each data field; and
* an ordered sequence of coded subfields within each data field.

Both fields and subfields can repeat.

MARCXML is the Library of Congress XML representation of MARC. In MARCXML, field tags and indicators are represented as attributes, while subfields are child elements carrying their subfield code as an attribute.

A faithful analytical representation therefore has to preserve the same distinctions that make the MARC record meaningful.

A small MARCXML data field looks like this:

```xml
<datafield tag="650" ind1=" " ind2="0">
  <subfield code="a">Totalitarianism</subfield>
  <subfield code="v">Fiction.</subfield>
</datafield>
```

The XML hierarchy keeps the two subfields attached to the same occurrence of
field `650`. This relationship becomes important as soon as fields or subfields
repeat.

### Why simple flattening loses information

A tempting representation of a bibliographic record is:

| record_id | title | author | subject |
|---:|---|---|---|
| 1 | Nineteen eighty four | George Orwell | Totalitarianism |

That table may be useful for one analysis, but it is not a general representation of the MARC record.

Consider these two MARC subject fields:

```text
650 _0 $a Totalitarianism $v Fiction
650 _0 $a Politics $x Philosophy
```

There are two distinct occurrences of field `650`. The first associates `$a Totalitarianism` with `$v Fiction`. The second associates `$a Politics` with `$x Philosophy`.

If the record is flattened independently by tag and subfield code, we might obtain:

```text
650$a = "Totalitarianism || Politics"
650$v = "Fiction"
650$x = "Philosophy"
```

All values are still present, but a relationship has disappeared. We can no longer infer with certainty which `$v` or `$x` belonged to which occurrence of field `650`.

The same problem appears inside one field when a subfield code repeats:

```text
700 1_ $a Smith, John $e editor $e translator
```

The two `$e` values are two ordered occurrences of the same subfield code inside one specific `700` field instance.

A general MARC representation therefore has to preserve several levels of identity and order:

```text
record
  ↓
field instance
  ↓
field tag, indicators, and field position
  ↓
ordered subfield instances
  ↓
subfield code, value, order, and occurrence
```

This is why one MARC record cannot safely be treated as one ordinary flat row without first making explicit choices about what information can be discarded.

## The canonical representation

This section defines the data contract used by all `marcxmlr` workflows. It is
important even for readers who already know MARC 21 well.

`marcxmlr` uses a long rectangular representation that makes MARC structure
explicit instead of discarding it.

### The 11 columns

Every result contains exactly these columns, in this order:

| Column | Type | Meaning |
|---|---|---|
| `record_id` | integer | Sequential identity assigned by `marcxmlr`; distinct from MARC control field `001`. |
| `field_type` | character | `leader`, `controlfield`, or `datafield`. |
| `tag` | character | `LDR` for the leader, otherwise the MARC field tag. |
| `subfield_code` | character | MARC subfield code; `NA` for leaders and control fields. |
| `value` | character | Textual value, preserving meaningful source content. |
| `field_order` | integer | Position of the field instance in the source record; the leader is `0`. |
| `field_occurrence` | integer | Occurrence number of the same field type and tag within the record. |
| `ind1` | character | First indicator for a data field; otherwise `NA`. |
| `ind2` | character | Second indicator for a data field; otherwise `NA`. |
| `subfield_order` | integer | Position of the subfield inside its containing data field; otherwise `NA`. |
| `subfield_occurrence` | integer | Occurrence number of that subfield code inside that particular field instance; otherwise `NA`. |

### Structural coordinates and analytical occurrence columns

The 11 columns deliberately contain a small amount of redundancy.

`field_order` and `subfield_order` are the structural ordering coordinates used
to identify field instances and reconstruct their order. Together with
`record_id`, `field_type`, `tag`, indicators, subfield codes and values, they
contain the information required to serialize the represented MARC structure.

`field_occurrence` and `subfield_occurrence` are **derived analytical
coordinates**. They are not strictly necessary to reconstruct MARCXML because
their values can be derived from the structural ordering coordinates.
`write_marcxml()` therefore does not use them as the authoritative source of
ordering.

They are included because repeated fields and repeated subfields are common in
MARC, and explicit occurrence numbers make analytical work considerably easier.
For example, they let ordinary `dplyr` code refer directly to:

* the first, second or later occurrence of tag `650` within a record; or
* the first, second or later `$y` subfield inside one particular `856` field.

They are therefore useful for filtering, grouping, joins, validation and
reshaping even though they can be derived from the structural ordering
coordinates.

For data fields, rows sharing the same `record_id` and `field_order` belong to
the same MARC field instance. `subfield_order` preserves the order within that
field. Those structural relationships are what make faithful reconstruction
possible.

### What semantic equivalence means

MARCXML expresses the logical MARC record through XML hierarchy. `marcxmlr` expresses the same analytical structure through explicit columns.

The canonical representation retains the information needed to distinguish:

* records;
* leaders and control fields;
* every data field instance;
* repeated field tags;
* both indicators;
* every subfield instance;
* repeated subfield codes; and
* field and subfield order.

The MARC hierarchy is encoded in columns rather than discarded.

Here, **semantic equivalence** means equivalence of the MARC record structure and values represented by MARCXML. It does not mean byte for byte reproduction of the XML serialization. XML declarations, namespace prefix spelling, indentation, attribute ordering, comments, and similar serialization details are not part of the analytical contract. Leaders, control fields, data field instances, indicators, subfields, repetition, and ordering are.

This is the central design choice of the package. A user can always derive a simpler representation later. Information discarded during import cannot be reconstructed reliably afterward.

### A complete example

Consider this deliberately small but structurally representative MARCXML record:

```xml
<?xml version="1.0" encoding="UTF-8"?>
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

The same record in the canonical representation has the following structure:

| record_id | field_type | tag | subfield_code | value | field_order | field_occurrence | ind1 | ind2 | subfield_order | subfield_occurrence |
|---:|---|---|---|---|---:|---:|---|---|---:|---:|
| 1 | leader | LDR | NA | 00000cam a2200000 i 4500 | 0 | 1 | NA | NA | NA | NA |
| 1 | controlfield | 001 | NA | 12345 | 1 | 1 | NA | NA | NA | NA |
| 1 | datafield | 100 | a | Orwell, George, | 2 | 1 | 1 | ` ` | 1 | 1 |
| 1 | datafield | 100 | d | 1903-1950. | 2 | 1 | 1 | ` ` | 2 | 1 |
| 1 | datafield | 245 | a | Nineteen eighty-four / | 3 | 1 | 1 | 0 | 1 | 1 |
| 1 | datafield | 245 | c | George Orwell. | 3 | 1 | 1 | 0 | 2 | 1 |
| 1 | datafield | 264 | a | London : | 4 | 1 | ` ` | 1 | 1 | 1 |
| 1 | datafield | 264 | b | Secker & Warburg, | 4 | 1 | ` ` | 1 | 2 | 1 |
| 1 | datafield | 264 | c | 1949. | 4 | 1 | ` ` | 1 | 3 | 1 |
| 1 | datafield | 650 | a | Totalitarianism | 5 | 1 | ` ` | 0 | 1 | 1 |
| 1 | datafield | 650 | v | Fiction. | 5 | 1 | ` ` | 0 | 2 | 1 |
| 1 | datafield | 650 | a | Dystopias. | 6 | 2 | ` ` | 0 | 1 | 1 |
| 1 | datafield | 650 | v | Fiction. | 6 | 2 | ` ` | 0 | 2 | 1 |
| 1 | datafield | 856 | u | https://example.org/1984 | 7 | 1 | 4 | 0 | 1 | 1 |
| 1 | datafield | 856 | y | Full text | 7 | 1 | 4 | 0 | 2 | 1 |
| 1 | datafield | 856 | y | Mirror | 7 | 1 | 4 | 0 | 3 | 2 |

Several important features are visible immediately:

* both `650` fields have tag `650`, but different `field_order` and `field_occurrence` values;
* `$v Fiction.` remains attached to the correct `650` instance because its rows share the same `field_order`;
* the two `856$y` values remain two distinct subfield instances, with `subfield_occurrence` equal to `1` and `2`;
* indicators remain attached to every row belonging to their data field instance; and
* source order is preserved at both field and subfield level.

Nothing forces the analyst to retain all of these columns forever. Their purpose is to make sure that the choice to discard structural information is made explicitly by the analyst rather than implicitly by the parser.

## Working with MARCXML in R

Once the MARC structure and the canonical representation are clear, the R
workflow is straightforward.

The package includes a small example collection:

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

The complete result is an ordinary tibble. The extract shows a repeated `$y`
subfield and makes the two occurrences directly visible.

### Check the representation before writing

Before creating a MARCXML file, it is useful to check that the R representation
still contains a coherent MARC structure. This matters especially after
filtering or modifying the data.

`diagnose_canonical()` performs this check. It inspects the canonical
representation without modifying it and without creating a file.

```r
diagnostics <- diagnose_canonical(marc)
diagnostics
#> # A tibble: 0 × 6
#> # ℹ 6 variables: severity <chr>, code <chr>, message <chr>, record_id <int>,
#> #   field_order <int>, subfield_order <int>
```

An empty diagnostics tibble means that no issue was found.

When diagnostics are present, each row reports a severity, a diagnostic code, a
human readable message, and the relevant record or position when available.

An `error` identifies a structural problem that prevents safe serialization. A
`warning` identifies something that deserves attention but does not make the
represented MARC structure ambiguous. For example, occurrence coordinates may
be stale or renumberable even when the structural ordering remains clear.

This distinction reflects the data model described above. `field_order` and
`subfield_order` determine structural order, while `field_occurrence` and
`subfield_occurrence` are derived analytical coordinates.

`write_marcxml()` performs the required structural checks itself before writing.
Calling `diagnose_canonical()` explicitly is useful when data have been filtered
or edited because the result can be inspected before any XML file is created.

The function checks the structural contract required by `marcxmlr`. It is not a
complete MARC 21 content validator and does not replace MARCXML schema
validation.

### Select records and export them as MARCXML

A practical use is to select records with ordinary `dplyr` syntax and share the
result again as MARCXML:

```r
selected <- marc |>
  filter(record_id == 1L)

out <- tempfile(fileext = ".xml")
write_marcxml(selected, out)

roundtrip <- read_marcxml(out)

identical(selected, roundtrip)
#> [1] TRUE
```

The selection happens in R, while the exported file is again MARCXML and can be
exchanged with software outside R. In this example, reading the exported file
reproduces the selected representation exactly.

### Modify repeated MARC data and write a new MARCXML file

The same workflow can include controlled edits. Here the second `856$y`
subfield is changed while the first one is left untouched:

```r
edited <- marc |>
  mutate(
    value = if_else(
      tag == "856" &
        subfield_code == "y" &
        subfield_occurrence == 2L,
      "Backup access",
      value
    )
  )

edited_xml <- tempfile(fileext = ".xml")
write_marcxml(edited, edited_xml)

read_marcxml(edited_xml) |>
  filter(record_id == 1L, tag == "856") |>
  select(subfield_code, value, subfield_occurrence)
#> # A tibble: 3 × 3
#>   subfield_code value                      subfield_occurrence
#>   <chr>         <chr>                                    <int>
#> 1 u             https://example.org/item/1                   1
#> 2 y             Full text                                    1
#> 3 y             Backup access                                2
```

The reread output shows that the second repeated value changed while the first
remained distinct. It also demonstrates why `subfield_occurrence` is useful in
analysis: a specific repetition can be addressed directly with ordinary
`dplyr` syntax.

### Query the canonical representation with `dplyr`

Once parsed, the canonical representation is an ordinary tibble. No special
query language is required.

The following examples use the complete Orwell record shown earlier. If that
MARCXML example is saved as `orwell.xml`, read it once with:

```r
orwell <- read_marcxml("orwell.xml")

dim(orwell)
#> [1] 16 11
```

#### Filter fields and subfields

A title statement can be selected directly by MARC tag:

```r
orwell |>
  filter(tag == "245") |>
  select(record_id, subfield_code, value)
#> # A tibble: 2 × 3
#>   record_id subfield_code value
#>       <int> <chr>         <chr>
#> 1         1 a             Nineteen eighty-four /
#> 2         1 c             George Orwell.
```

Occurrence coordinates make repeated fields equally easy to inspect:

```r
orwell |>
  filter(tag == "650", subfield_code == "a") |>
  select(record_id, field_occurrence, value)
#> # A tibble: 2 × 3
#>   record_id field_occurrence value
#>       <int>            <int> <chr>
#> 1         1                1 Totalitarianism
#> 2         1                2 Dystopias.
```

#### Keep a complete field when one subfield matches

Grouping by `record_id` and `field_order` lets a condition select the complete
MARC field instance rather than only the row that matched:

```r
orwell |>
  group_by(record_id, field_order) |>
  filter(
    any(
      tag == "650" &
        subfield_code == "a" &
        value == "Totalitarianism"
    )
  ) |>
  ungroup() |>
  select(
    record_id,
    field_order,
    tag,
    subfield_code,
    value
  )
#> # A tibble: 2 × 5
#>   record_id field_order tag   subfield_code value
#>       <int>       <int> <chr> <chr>         <chr>
#> 1         1           5 650   a             Totalitarianism
#> 2         1           5 650   v             Fiction.
```

The condition matches only `$a Totalitarianism`, but the result also contains
its associated `$v Fiction.` because both rows belong to the same `650` field
instance.

#### Reconstruct a convenient field view

The preserved structure can also be used to create a compact field view for
inspection:

```r
orwell |>
  filter(field_type == "datafield") |>
  group_by(record_id, field_order, tag, ind1, ind2) |>
  summarise(
    field = paste0(
      "$", subfield_code, " ", value,
      collapse = " "
    ),
    .groups = "drop"
  ) |>
  select(record_id, field_order, tag, field)
#> # A tibble: 6 × 4
#>   record_id field_order tag   field
#>       <int>       <int> <chr> <chr>
#> 1         1           2 100   $a Orwell, George, $d 1903-1950.
#> 2         1           3 245   $a Nineteen eighty-four / $c George Orwell.
#> 3         1           4 264   $a London : $b Secker & Warburg, $c 1949.
#> 4         1           5 650   $a Totalitarianism $v Fiction.
#> 5         1           6 650   $a Dystopias. $v Fiction.
#> 6         1           7 856   $u https://example.org/1984 $y Full text $y Mirror
```

This simpler view is derived only after the canonical representation has
preserved the original grouping.

#### Derive a simplified analytical table

For a particular analysis, the full MARC structure may no longer be needed. For
example, one title and a combined set of subject headings can be derived with
ordinary `dplyr` operations:

```r
titles <- orwell |>
  filter(tag == "245", subfield_code == "a") |>
  transmute(record_id, title = value)

subjects <- orwell |>
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
#>   record_id title                   subjects
#>       <int> <chr>                   <chr>
#> 1         1 Nineteen eighty-four /  Totalitarianism ; Fiction. | Dystopias. ; Fiction.
```

The important asymmetry is:

> **Canonical to simplified is easy. Simplified to canonical may be impossible.**

`marcxmlr` therefore preserves structure first and lets the user decide what can
safely be collapsed for a particular analytical purpose.

## Real data, large collections and performance

### Small real world example: Library of Congress

The Library of Congress publishes a MARCXML record for Carl Sandburg's *Arithmetic*. It is a useful small example because the XML and MARC structure can be inspected directly.

On Linux:

```bash
mkdir -p data/loc

curl --fail --location \
  "https://www.loc.gov/standards/marcxml/Sandburg/sandburg.xml" \
  --output data/loc/sandburg.xml
```

Then in R:

```r
library(marcxmlr)
library(dplyr)

sandburg <- read_marcxml("data/loc/sandburg.xml")

sandburg |>
  filter(tag == "245") |>
  select(
    subfield_code,
    value
  )
```

Output:

```text
# A tibble: 2 × 2
  subfield_code value
  <chr>         <chr>
1 a             Arithmetic /
2 c             Carl Sandburg ; illustrated as an anamorphic adventure by Ted Rand.
```

The point is not that tag `245` is difficult to extract. The point is that the exact same representation remains safe when fields and subfields repeat in much less convenient records.

### Choose an in memory or Parquet workflow

Both workflows use the same canonical representation. The practical difference
is where that representation lives.

Use `read_marcxml()` when the XML document and the parsed result fit comfortably
in memory. The bundled example used above returns one ordinary tibble:

```r
marc <- read_marcxml(source_xml)

dim(marc)
#> [1] 18 11
```

`n_max` can restrict parsing to the first records, which is useful for previews
and development:

```r
preview <- read_marcxml(
  source_xml,
  n_max = 1L
)

unique(preview$record_id)
#> [1] 1
```

For much larger collections, materializing tens of millions of canonical rows
as one tibble may be unnecessary. `marcxml_to_parquet()` writes the same schema
to a directory of Parquet files while keeping normal working memory bounded by
the configured processing batches.

Install Arrow support if necessary:

```r
install.packages("arrow")
```

The same bundled MARCXML example can be converted to Parquet:

```r
out_dir <- tempfile()

marcxml_to_parquet(
  source_xml,
  output_dir = out_dir,
  workers = 1L
)

catalogue <- arrow::open_dataset(out_dir)

catalogue |>
  summarise(rows = n()) |>
  collect()
#> # A tibble: 1 × 1
#>    rows
#>   <int>
#> 1    18
```

For a large single file, the pattern is the same:

```r
marcxml_to_parquet(
  "catalogue.xml",
  output_dir = "catalogue_parquet",
  workers = 1L
)
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

A glob pattern can also be supplied directly.

The resulting dataset can be queried with Arrow and `dplyr` without first
loading the complete canonical table into R:

```r
catalogue <- arrow::open_dataset("catalogue_parquet")

catalogue |>
  filter(tag == "650", subfield_code == "a") |>
  count(value, sort = TRUE) |>
  head(20) |>
  collect()
```

The result is an ordinary tibble containing up to twenty subject values and
their counts. The actual values depend on the catalogue being queried:

```text
# A tibble: up to 20 × 2
  value                                      n
  <chr>                                  <int>
  ...
```

Arrow can apply filters, projections, and aggregations before the selected
result is brought into R.

#### Global record identity across files

When several MARCXML files are converted into one dataset, `marcxmlr` assigns
globally contiguous `record_id` values in deterministic input file order. The
result therefore behaves as one logical collection even when the physical
source is split across many XML files.

Worker completion order does not change record identity.

### Performance on public data

The main large scale development benchmark uses the U.S. Government Publishing
Office public **All CGP Records (MARC XML)** dataset:

https://github.com/usgpo/cataloging-records-all-cgp-marcxml

One 40,000 record GPO file produced **2,143,952 canonical rows**. Development
measurements on the machines used for `marcxmlr` gave approximately:

| Workflow | Input | Elapsed time |
|---|---:|---:|
| `read_marcxml()` | 40,000 records | about 6.5 s |
| `marcxml_to_parquet()` | 40,000 records | about 8.4 s |
| `write_marcxml()` from lazy Arrow, checks enabled | 2,143,952 rows | about 14 to 15 s |
| `write_marcxml()` from lazy Arrow, `check = FALSE` | 2,143,952 rows | about 9 s |

A larger Parquet conversion over **27 GPO MARCXML files** contained
**1,080,000 records** and produced **67,672,396 canonical rows** in about
**100 seconds with 7 workers**.

These are development measurements, not performance guarantees. Hardware,
storage, R, libxml2, and Arrow versions all matter. Part II explains the native
implementation, memory model, parallel execution, and benchmark methodology.

# Part II: Under the hood: implementation and performance

Part I is sufficient for using `marcxmlr`. Part II explains how the package
implements reading, Parquet conversion, structural checks, and MARCXML writing
around the same canonical representation.


## Architecture

The public workflows share one canonical representation but use different
execution paths according to the direction and size of the data.

The public workflows share one data model, but use different execution paths
according to the direction and size of the data.

### Read MARCXML into memory

```text
MARCXML file
      ↓
libxml2 document
      ↓
native MARC parser
      ↓
canonical columns
      ↓
R tibble
```

`read_marcxml()` is the direct in memory path. R initiates the operation, while
the repeated traversal of MARC fields and subfields happens in compiled C code
using libxml2 nodes directly.

The native parser first determines how many canonical rows are required, then
allocates the output columns at their final size and fills them in a second
pass. This avoids repeatedly enlarging large R objects.

### Convert MARCXML to Parquet

```text
MARCXML collection
      ↓
stream complete records
      ↓
native MARC parser
      ↓
canonical batches
      ↓
Parquet parts
      ↓
Arrow dataset
```

`marcxml_to_parquet()` is the bounded memory path for larger collections.
Complete records are processed incrementally and canonical rows are written to
Parquet instead of being accumulated as one large R object.

The record is the unit that must remain intact. A batch boundary can occur
between records, but a record is not divided in a way that would lose the
relationships among its fields and subfields.

When several input files are converted together, global `record_id` values are
assigned from deterministic file order rather than worker completion order.

### Write MARCXML

```text
canonical representation
      ↓
structural checks
      ↓
native libxml2 writer
      ↓
MARCXML collection
```

`write_marcxml()` uses the canonical representation in the opposite direction.
For an in memory tibble, the package checks the represented structure and native
libxml2 `xmlTextWriter` code serializes complete records directly.

For an Arrow `Dataset` or lazy Arrow query, rows are consumed incrementally.
At most one incomplete record is carried across a batch boundary, and a
persistent native writer receives complete records progressively. Finite
`records_per_file` sharding closes and opens collections only at record
boundaries.

Output is staged before publication. Existing output is not silently
overwritten, and a serialization failure does not publish a partial output
family.

### Structural checks and serialization rules

Serialization is governed by the structural coordinates of the canonical
representation. In particular, `record_id`, `field_order`, and
`subfield_order`, together with field types, tags, indicators, subfield codes,
and values, determine the MARC structure to be written.

`field_occurrence` and `subfield_occurrence` are derived analytical coordinates.
They are useful for analysis, but they are not the authoritative source of
serialization order.

This distinction also determines diagnostic severity. Structural ambiguity is
an error because the writer cannot safely infer the intended MARC structure.
Stale or renumberable occurrence coordinates can instead be warnings when the
structural ordering remains unambiguous.

`write_marcxml()` enforces structural errors before writing. With
`check = TRUE`, it also reports warning level diagnostics.

The checks cover the structural contract required by `marcxmlr`, including
record and field organization, ordering information, indicators, required
leader structure, duplicate structural positions, and XML 1.0 character
validity. They do not constitute complete MARC 21 content validation or
MARCXML schema validation.

For untouched canonical data, a read, write, read cycle preserves the
represented MARC semantics: leaders, control fields, data field instances,
indicators, subfields, repetition, values, and ordering. XML formatting choices
such as indentation, namespace prefix spelling, and attribute order are outside
that contract.


## Native implementation and validation

### Why the native implementation is fast

A straightforward XML to table implementation in R can spend substantial time
on repeated high level operations:

```text
many small XML queries
      ↓
many temporary R objects
      ↓
many transitions between R and compiled XML code
      ↓
repeated reshaping and counting
```

`marcxmlr` instead moves the repeated structural work into coarse native
operations:

```text
one R call
      ↓
native traversal of libxml2 nodes
      ↓
direct construction of canonical columns
      ↓
completed R result
```

The gain is therefore not only that compiled code executes individual
instructions quickly. The larger gain comes from changing the granularity of
the work.

The parser performs MARC traversal, output sizing, field ordering, subfield
ordering, and occurrence bookkeeping while it already has the record in hand.
Occurrence counters are computed during parsing rather than reconstructed later
with grouped R operations.

For large output, Parquet avoids forcing tens of millions of canonical rows
into one R object. For large input to the writer, lazy Arrow input similarly
avoids materializing an entire dataset solely to serialize it.

### Reference implementations and tests

The optimized native paths are the production performance paths, but independent
implementations remain useful.

The package retains R and XML based parsing paths where they are needed for
compatibility and fallback behavior. The writer also retains an R and `xml2`
reference implementation internally for semantic comparison in tests.

These paths are valuable because optimized native code can be checked against
an independently implemented result rather than merely against itself.

The test suite compares native and reference behavior across repeated fields,
repeated subfields, indicators, ordering, Unicode, XML metacharacters,
streaming boundaries, sharding, failure behavior, and parallel execution.

## Parallelism and deterministic behavior

Both reading and Parquet conversion default to sequential execution.

For one MARCXML file, the optimized native sequential path is usually the best
starting point. Process creation, task scheduling, serialization, and result
coordination can cost more than they save once the parser itself is fast.

A catalogue already split across several files provides a more natural unit of
parallel work:

```text
file 1 → sequential native parser → Parquet parts
file 2 → sequential native parser → Parquet parts
file 3 → sequential native parser → Parquet parts
```

Each worker receives a complete file and uses the optimized sequential engine
internally. Deterministic record offsets are assigned from ordered inputs before
parallel work begins, so worker completion order does not change global record
identity.

The package uses scoped Futureverse plans so temporary parallel configuration
does not replace the caller's plan after the operation completes. Where
sequential and parallel branches perform the same mapping operation,
conditional futurization is used. Where the algorithms are genuinely
different, such as deterministic multi file Parquet conversion, the separate
algorithms remain explicit.

The MARCXML writer deliberately has no public worker argument. Development
benchmarks showed only modest gains from process level writer parallelism, while
process transfer, memory use, repeated Arrow scans, and output coordination
would make the design more complex. The lazy writer therefore remains a single
pass bounded stream.

## Benchmark methodology

Part I reports the headline timings because they help users judge scale. The
technical interpretation belongs here.

The main development dataset is the U.S. Government Publishing Office public
All CGP Records MARCXML collection. The commonly used single file sample
contains 40,000 records and produces 2,143,952 canonical rows. Larger tests use
multiple files from the same public collection.

The reported timings are complete workflow measurements rather than isolated
microbenchmarks. A `read_marcxml()` timing includes the work required to return
the R result. A Parquet timing includes conversion and publication of the
dataset. Writer timings include the complete serialization path appropriate to
the input type.

Benchmark results depend on more than the package version. Reproducible
comparisons should record at least:

* the exact `marcxmlr` version or Git commit;
* R version;
* libxml2 version;
* Arrow version where relevant;
* operating system;
* CPU;
* storage;
* exact input files or checksums; and
* worker count.

The benchmark numbers in Part I should therefore be read as scale indicators
for the documented development environment, not as performance guarantees.

The implementation principle is simple: preserve the MARC structure first,
then optimize the repeated work without changing that representation.
