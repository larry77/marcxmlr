# marcxmlr

[![R-CMD-check](https://github.com/larry77/marcxmlr/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/larry77/marcxmlr/actions/workflows/R-CMD-check.yaml)
[![CRAN status](https://www.r-pkg.org/badges/version/marcxmlr)](https://CRAN.R-project.org/package=marcxmlr)

`marcxmlr` helps bring MARC 21 data into ordinary R data workflows.

MARC 21 is a widely used format for representing bibliographic and related
metadata. In many data-exchange workflows, MARC 21 records are distributed as
MARCXML: an XML representation in which records contain ordered fields,
indicators and subfields, and where both fields and subfields may repeat.

This structure is well suited to representing MARC records, but it is less
convenient for analytical work. An analyst using R and the tidyverse usually
wants data in a rectangular form that can be filtered, grouped, joined,
reshaped and summarized with familiar tools such as `dplyr`. MARCXML does not
naturally fit that model: simply flattening the XML can lose information about
repeated fields, repeated subfields, indicators and the relationships among
them.

`marcxmlr` provides a bridge between these two worlds. It reads MARCXML into a
tidy rectangular representation while preserving the structure needed to
distinguish the different parts of a MARC record. The resulting data can be
analysed and manipulated with ordinary R tools.

It can also perform the reverse operation. A structurally valid representation
can be written back to MARCXML, making it possible to select or modify MARC data
in R and then export the result again in the established MARCXML format.

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

The exact tabular representation used by `marcxmlr` is introduced later, once
the basic workflow and the reason for preserving MARC structure are clear.

## Stable CRAN release and GitHub development version

The CRAN badge above reports the version currently available from CRAN. CRAN is
the stable release channel.

This README documents the current GitHub `main` branch. GitHub development can
therefore move ahead of CRAN between releases. The tagged
[`v0.3.0`](https://github.com/larry77/marcxmlr/tree/v0.3.0) tag is an
immutable snapshot of version 0.3.0, while `main` uses the conventional
`.9000` development-version suffix.

Install the stable CRAN release with:

```r
install.packages("marcxmlr")
```

Install the current GitHub development version with:

```r
# install.packages("pak")
pak::pak("larry77/marcxmlr")
```

The round-trip functionality described below was introduced in version 0.3.0.
If the CRAN badge shows an earlier version, install the GitHub version to use
`write_marcxml()`, `diagnose_canonical()`, and the round-trip examples in this
README.

Source installation of the GitHub version requires a C toolchain and libxml2
development headers/libraries. On Debian/Ubuntu these are normally provided by
`r-base-dev` and `libxml2-dev`; Windows source builds use Rtools.

# Part I: Using and understanding `marcxmlr`

Part I explains the data model first and the R workflow second. Readers who
already know MARC 21 can skip the short MARC introduction, but the discussion of
flattening and the canonical representation is central to the package.


## MARC 21, MARCXML and the tabular problem

### MARC 21 and MARCXML

Readers who already work with MARC 21 and MARCXML can skip this subsection.
The explanation of flattening that follows is important for understanding why
`marcxmlr` uses its particular tabular representation.

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

### The 11 columns

This section defines the data contract used by all `marcxmlr` workflows.
It is worth reading even for readers who already know MARC 21 well.

`marcxmlr` solves this by using a long rectangular representation that makes MARC structure explicit instead of discarding it.

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
coordinates**. They are not strictly necessary to reconstruct MARCXML and
`write_marcxml()` does not use them as the authoritative source of ordering.

They are included because repeated fields and repeated subfields are common in
MARC, and explicit occurrence numbers make analytical work considerably easier.
For example, they let ordinary `dplyr` code refer directly to:

* the first, second or later occurrence of tag `650` within a record; or
* the first, second or later `$y` subfield inside one particular `856` field.

They are therefore useful for filtering, grouping, joins, validation and
reshaping even though they can be derived from the structural ordering
coordinates. `diagnose_canonical()` treats stale or renumberable occurrence
coordinates as analytical-coordinate issues rather than structural ambiguity.

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

An empty diagnostics tibble means that no structural or warning level issue was
found.

When diagnostics are present, each row identifies the severity, a diagnostic
code, a human readable message, and the relevant record or field position when
available. An `error` identifies a structural problem that prevents safe
serialization. A `warning` identifies an issue that deserves attention but does
not necessarily make the represented MARC structure ambiguous. Typical warning
level cases include stale or renumberable analytical coordinates.

The distinction matters because `field_occurrence` and `subfield_occurrence`
are useful analytical coordinates, but they are not the structural source of
ordering used to reconstruct MARCXML.

`write_marcxml()` performs structural checks before writing. Calling
`diagnose_canonical()` explicitly is useful during analysis and editing because
the diagnostics can be inspected before any output file is created.

`diagnose_canonical()` is not a complete MARC 21 content validator and it is not
a replacement for schema validation. Its purpose is narrower: it checks whether
the `marcxmlr` canonical representation is structurally safe to serialize.

### Select records and export them as MARCXML

A practical use is to select records with ordinary `dplyr` syntax and share the
result again as MARCXML:

```r
selected <- marc |>
  filter(record_id == 1L)

diagnose_canonical(selected)
#> # A tibble: 0 × 6
#> # ℹ 6 variables: severity <chr>, code <chr>, message <chr>, record_id <int>,
#> #   field_order <int>, subfield_order <int>

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

diagnose_canonical(edited)
#> # A tibble: 0 × 6
#> # ℹ 6 variables: severity <chr>, code <chr>, message <chr>, record_id <int>,
#> #   field_order <int>, subfield_order <int>

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

Once parsed, the result is an ordinary tibble. No special query language is required.

The examples in this section use `dplyr`. Install it if necessary:

```r
install.packages("dplyr")
```

Then load it:

```r
library(dplyr)
```

#### Extract title statements

```r
orwell |>
  filter(tag == "245") |>
  select(record_id, subfield_code, value)
```

Output:

```text
# A tibble: 2 × 3
  record_id subfield_code value
      <int> <chr>         <chr>
1         1 a             Nineteen eighty-four /
2         1 c             George Orwell.
```

#### Extract main subject terms

```r
orwell |>
  filter(tag == "650", subfield_code == "a") |>
  select(record_id, field_occurrence, value)
```

Output:

```text
# A tibble: 2 × 3
  record_id field_occurrence value
      <int>            <int> <chr>
1         1                1 Totalitarianism
2         1                2 Dystopias.
```

#### Keep complete field instances when one subfield matches

Grouping by `record_id` and `field_order` lets a condition select a complete MARC field rather than only the row that matched:

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
```

Output:

```text
# A tibble: 2 × 5
  record_id field_order tag   subfield_code value
      <int>       <int> <chr> <chr>         <chr>
1         1           5 650   a             Totalitarianism
2         1           5 650   v             Fiction.
```

The condition matched only `$a Totalitarianism`, but the result contains both that row and its associated `$v Fiction.` because they belong to the same `650` field instance.

#### Render complete data fields for inspection

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
```

Output:

```text
# A tibble: 6 × 4
  record_id field_order tag   field
      <int>       <int> <chr> <chr>
1         1           2 100   $a Orwell, George, $d 1903-1950.
2         1           3 245   $a Nineteen eighty-four / $c George Orwell.
3         1           4 264   $a London : $b Secker & Warburg, $c 1949.
4         1           5 650   $a Totalitarianism $v Fiction.
5         1           6 650   $a Dystopias. $v Fiction.
6         1           7 856   $u https://example.org/1984 $y Full text $y Mirror
```

This produces a convenient field level view only after the canonical representation has already preserved the original grouping.

#### Derive a simplified table when the analysis permits it

For a particular task, you may decide that only one title and a set of subject headings matter:

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
```

Output:

```text
# A tibble: 1 × 3
  record_id title                   subjects
      <int> <chr>                   <chr>
1         1 Nineteen eighty-four /  Totalitarianism ; Fiction. | Dystopias. ; Fiction.
```

The important asymmetry is:

> **Canonical to simplified is easy. Simplified to canonical may be impossible.**

`marcxmlr` therefore preserves structure at ingestion and lets the user decide what can safely be collapsed for a particular analytical purpose.

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

### In memory work

Use `read_marcxml()` when the XML document and the parsed result fit comfortably in memory:

```r
marc <- read_marcxml(
  "records.xml",
  workers = 1L
)
```

The function accepts a MARCXML collection or a standalone record and returns the canonical 11 column tibble.

`n_max` can restrict the number of records parsed, which is useful for previews and development:

```r
preview <- read_marcxml(
  "records.xml",
  n_max = 100L
)
```

This is the simplest workflow and the best place to start.

### Large collections with Parquet

For larger collections, materializing tens of millions of canonical rows as one tibble may be unnecessary. `marcxml_to_parquet()` writes the same schema as a directory of Parquet files while keeping normal working memory bounded by the configured processing batches.

To use the Parquet workflow, install the additional packages required for it:

```r
install.packages(c("XML", "arrow"))
```

Single file:

```r
marcxml_to_parquet(
  "catalogue.xml",
  output_dir = "catalogue_parquet",
  workers = 1L
)
```

Multiple files:

```r
files <- sort(Sys.glob("data/catalogue/*.xml"))

marcxml_to_parquet(
  files,
  output_dir = "catalogue_parquet",
  workers = 4L
)
```

A glob pattern can also be supplied directly.

To query the resulting dataset with Arrow and `dplyr`, install `dplyr` as shown earlier and then:

```r
library(arrow)
library(dplyr)

catalogue <- open_dataset("catalogue_parquet")

catalogue |>
  filter(tag == "650", subfield_code == "a") |>
  count(value, sort = TRUE) |>
  head(20) |>
  collect()
```

The result is an ordinary tibble with one row for each of the most frequent `650$a` values and a column named `n` containing the count. The actual terms and counts depend on the catalogue being queried.

```text
# A tibble: up to 20 × 2
  value                                      n
  <chr>                                  <int>
  ...
```

`open_dataset()` lets Arrow apply filters, projections, and aggregations before selected results are brought into R.

#### Global record identity across files

When several MARCXML files are converted into one dataset, `marcxmlr` assigns globally contiguous `record_id` values in deterministic input file order. The result therefore behaves as one logical collection even when the physical source is split across many XML files.

Worker completion order does not change record identity.

### Performance on public data

The main large scale development benchmark uses the U.S. Government Publishing
Office public **All CGP Records (MARC XML)** dataset:

<https://github.com/usgpo/cataloging-records-all-cgp-marcxml>

One 40,000-record GPO file produced **2,143,952 canonical rows**. Development
measurements on the machines used for `marcxmlr` gave approximately:

| Workflow | Input | Elapsed time |
|---|---:|---:|
| `read_marcxml()` | 40,000 records | about 6.5 s |
| `marcxml_to_parquet()` | 40,000 records | about 8.4 s |
| `write_marcxml()` from lazy Arrow, checks enabled | 2,143,952 rows | about 14-15 s |
| `write_marcxml()` from lazy Arrow, `check = FALSE` | 2,143,952 rows | about 9 s |

A larger Parquet conversion over **27 GPO MARCXML files** contained
**1,080,000 records** and produced **67,672,396 canonical rows** in about
**100 seconds with 7 workers**.

These are development measurements, not performance guarantees. Hardware,
storage, R, libxml2 and Arrow versions all matter.

A minimal in memory benchmark is:

```r
system.time({
  x <- read_marcxml("gpo-40000.xml")
})

nrow(x)
length(unique(x$record_id))
```

For an in memory write benchmark on the parsed tibble:

```r
system.time({
  write_marcxml(x, "gpo-40000-roundtrip.xml")
})
```

For collections that should stay out of one large R object:

```r
system.time({
  marcxml_to_parquet(
    "gpo-40000.xml",
    output_dir = "gpo-parquet"
  )
})
```

Part II explains the native libxml2 implementation, bounded memory architecture,
parallel execution and benchmark methodology.

# Part II: Under the hood: implementation and performance

Part I is sufficient for using `marcxmlr`. This part explains how the package
implements the same canonical representation across reading, large collection
conversion, diagnostics, and MARCXML writing.

## Three execution paths

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

## Diagnostics and serialization rules

The writer reconstructs MARC structure from structural coordinates, especially
`record_id`, `field_order`, and `subfield_order`, together with field types,
tags, indicators, subfield codes, and values.

`field_occurrence` and `subfield_occurrence` are different. They are derived
analytical coordinates. They make repeated MARC structure easy to select,
group, join, inspect, and validate, but they are not the authoritative source
of serialization order.

This distinction explains the behavior of `diagnose_canonical()`. Structural
ambiguity is an error because the package cannot safely decide what MARC
structure to write. Stale or renumberable analytical coordinates can instead be
reported as warnings because the represented structure can still be
unambiguous.

Structural errors are enforced when writing. With `check = TRUE`,
`write_marcxml()` also reports warning level diagnostics before serialization.

The diagnostics cover the structural contract needed by `marcxmlr`, including
record and field organization, ordering information, indicators, required
leader structure, duplicate structural positions, and XML 1.0 character
validity.

They are not a complete MARC 21 content validator. The package does not claim
that every coded value, cataloguing convention, or external MARC rule is valid
merely because a canonical representation can be serialized safely.

For an untouched canonical table, a read, write, read cycle preserves the
represented MARC semantics: leaders, control fields, data field instances,
indicators, subfields, repetition, values, and ordering. XML formatting details
such as indentation, namespace prefix spelling, attribute order, and similar
serialization choices are outside that contract.

## Why the native implementation is fast

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

## Compatibility and reference paths

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
