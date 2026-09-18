# marcxmlr

[![R-CMD-check](https://github.com/larry77/marcxmlr/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/larry77/marcxmlr/actions/workflows/R-CMD-check.yaml)
[![CRAN status](https://www.r-pkg.org/badges/version/marcxmlr)](https://CRAN.R-project.org/package=marcxmlr)

`marcxmlr` reads MARC 21 XML into R as a faithful rectangular table. It preserves leaders, control fields, data fields, indicators, repeated fields, repeated subfields, and source order, so MARC records can be analysed with ordinary R tools without flattening away the structure that gives them meaning.

Install the package from CRAN:

```r
install.packages("marcxmlr")
```

To install the current development version from GitHub:

```r
remotes::install_github("larry77/marcxmlr")
```

Then parse a MARCXML file:

```r
library(marcxmlr)

marc <- read_marcxml("records.xml")
marc
```

That is enough to get started.

The result is a canonical 11 column representation of MARC 21. The first part of this README explains what that representation means, why MARC cannot safely be treated as an ordinary flat table, and how to query the result. The second part explains how the package achieves high throughput with compiled C code, libxml2, bounded streaming, and carefully placed parallelism.

# Part I: Using and understanding `marcxmlr`

## Why another R package for MARCXML?

R already has strong general XML tools. `xml2` provides modern libxml2 bindings and XPath based XML manipulation. `XML` provides tree, XPath, event, and SAX facilities. There is also MARC specific work in R, including the `maRc` project, which exposes MARCXML records through record oriented R6 objects.

`marcxmlr` addresses a different problem.

Its purpose is to turn complete MARCXML collections into a documented, analysis friendly representation that remains faithful to repeated MARC structure and that can scale from a single record to very large catalogues.

The package combines several properties that are particularly useful for analytical work:

1. a documented MARC aware rectangular representation that does not silently collapse repeated structure;
2. explicit preservation of field order, field occurrence, subfield order, subfield occurrence, and indicators;
3. the same canonical representation for ordinary in memory work and large Parquet workflows;
4. direct conversion of large MARCXML collections to Parquet; and
5. an implementation designed to remain practical on collections containing millions of MARC records.

The distinction is about scope. `marcxmlr` is not a replacement for general XML libraries or for record oriented MARC software. Its design target is a faithful analytical representation of MARC collections in R.

| Tool | Main role | Difference from `marcxmlr` |
|---|---|---|
| `xml2` | General XML parsing and manipulation | Understands XML structure, but does not define the MARC specific canonical representation used here. |
| `XML` | General XML parsing, XPath, event, and streaming interfaces | Supplies powerful XML machinery, but not a MARC specific analytical contract. |
| `maRc` | Record oriented MARCXML access through R6 objects | Provides MARC aware record access. `marcxmlr` focuses on a collection oriented rectangular representation and large scale Parquet workflows. |

## Scope: what `marcxmlr` does and does not do

`marcxmlr` is a parser and rectangling package. Its job is to represent the information and structure present in MARCXML faithfully enough that later analysis does not have to guess what was lost during import.

It deliberately does not try to become a catalogue management system or a MARC repair engine. In particular, it does not:

* correct malformed or semantically incorrect MARC 21 records;
* infer missing fields, indicators, or subfields;
* normalize different cataloguing practices into a common local convention;
* validate every MARC content rule or coded value;
* merge duplicate bibliographic records;
* decide which repeated values should be collapsed for a particular analysis;
* map the catalogue automatically to another metadata model such as Dublin Core or BIBFRAME; or
* replace an integrated library system.

The guiding principle is simple: **preserve first, interpret later**.

If a source record is structurally usable, `marcxmlr` aims to represent what is actually there. If the input violates assumptions required for safe parsing, failure is preferable to silently manufacturing a repaired interpretation.

The package therefore separates three activities:

```text
MARCXML parsing
      ↓
faithful canonical representation
      ↓
analysis, selection, reshaping, mapping, validation, or transformation
```

`marcxmlr` concentrates on the first two. The third is left to ordinary R tools and to domain rules chosen by the user.

## Fast enough for real catalogues

Faithfulness is useful only if it remains practical at catalogue scale. `marcxmlr` therefore places the performance critical parsing work in compiled C code built directly on libxml2.

A development benchmark on a public U.S. Government Publishing Office MARCXML file containing **40,000 records** produced **2,143,952 canonical rows** in approximately:

| Operation | Workers | Elapsed time |
|---|---:|---:|
| `read_marcxml()` | 1 | about 6.5 s |
| `marcxml_to_parquet()` | 1 | about 8.4 s |

A larger run over **27 GPO MARCXML files**, containing **1,080,000 records** and producing **67,672,396 canonical rows**, completed in about **100 seconds with 7 workers**.

These timings depend on hardware and software, so they are scale indicators rather than guarantees. The important point is architectural: the expensive traversal, counting, and result construction are handled in native code rather than by millions of small R level XML operations.

The detailed implementation and reproducible benchmark patterns are documented in [Part II](#part-ii-under-the-hood-implementation-and-performance).

## What are MARC 21 and MARCXML?

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

## Why MARC 21 is not tabular data

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

## The canonical 11 column representation

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

### Why these columns are enough

The representation is intentionally explicit.

* `record_id` tells us which MARC record a row belongs to.
* `field_order` identifies one specific field instance within that record and preserves its source position.
* `field_occurrence` makes repetition of the same tag explicit.
* `ind1` and `ind2` remain attached to the data field instance.
* `subfield_order` preserves the order of subfields inside the field.
* `subfield_occurrence` distinguishes repeated uses of the same subfield code inside one field.

For data fields, all rows belonging to the same `record_id` plus `field_order` combination belong to the same MARC field instance.

That is the key to the representation. The table is rectangular, but MARC itself is not forced into a flat model.

## Semantic equivalence to the MARC record

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

## A complete small MARCXML record

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

If the file is saved as `orwell.xml`:

```r
library(marcxmlr)

orwell <- read_marcxml("orwell.xml")
orwell
```

The canonical result has the following structure:

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

## Querying the canonical representation with `dplyr`

Once parsed, the result is an ordinary tibble. No special query language is required.

The examples in this section use `dplyr`. Install it if necessary:

```r
install.packages("dplyr")
```

Then load it:

```r
library(dplyr)
```

### Extract title statements

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

### Extract main subject terms

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

### Keep complete field instances when one subfield matches

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

### Render complete data fields for inspection

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

### Derive a simplified table when the analysis permits it

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

## Small real world example: Library of Congress

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

## In memory work with `read_marcxml()`

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

## Large collections with `marcxml_to_parquet()`

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

### Global record identity across files

When several MARCXML files are converted into one dataset, `marcxmlr` assigns globally contiguous `record_id` values in deterministic input file order. The result therefore behaves as one logical collection even when the physical source is split across many XML files.

Worker completion order does not change record identity.

## Parallel processing

Both public workflows default to `workers = 1L`.

For a single MARCXML file, start with sequential execution. The native parser is fast enough that process creation, record dispatch, serialization, and coordination can cost more than they save.

Parallelism becomes more attractive when a collection is naturally divided across multiple input files. Complete files can then be processed independently, while each worker uses the optimized sequential parser internally.

If you want to use optional parallel execution, install the supporting packages:

```r
install.packages(c(
  "future",
  "future.mirai",
  "futurize",
  "furrr",
  "mori"
))
```

A reasonable pattern is:

```r
workers <- max(
  1L,
  as.integer(future::availableCores()) - 1L
)

marcxml_to_parquet(
  sort(Sys.glob("data/catalogue/*.xml")),
  output_dir = "catalogue_parquet",
  workers = workers
)
```

Benchmark on the actual machine and input. XML size, average record complexity, storage speed, worker startup, Parquet compression, and memory bandwidth all influence the result.

## Memory and failure model

The two workflows deliberately have different memory guarantees:

| Function | XML ingestion | Parsed result |
|---|---|---|
| `read_marcxml()` | Builds the document needed for in memory parsing | Complete canonical tibble is returned in memory |
| `marcxml_to_parquet()` | Processes complete records incrementally | Canonical rows are written to Parquet parts; only a summary is returned |

Bounded memory does not mean constant memory. An unusually large individual record still has to be represented while it is being processed, and multiple workers naturally increase concurrent memory use.

For Parquet conversion, output is first written under a staging directory. The requested dataset directory is published only after successful conversion, and an existing output directory is not silently overwritten. This reduces the risk of mistaking a partially written dataset for a complete one.

# Part II: Under the hood: implementation and performance

Everything above is sufficient to use `marcxmlr` correctly. This part is optional for ordinary use. It is intended for readers who want to understand how the package preserves a rich MARC representation while processing large collections at high speed.

The short answer is simple: **the expensive loops are not R loops**.

The public interface remains ordinary R, while the performance critical parsing path is implemented in compiled C code using libxml2 directly.

## Architectural overview

### In memory parsing

```text
┌──────────────────────┐
│ MARCXML file         │
└──────────┬───────────┘
           ↓
┌──────────────────────┐
│ libxml2 document     │
└──────────┬───────────┘
           ↓
┌──────────────────────┐
│ native MARC parser   │
│ implemented in C     │
└──────────┬───────────┘
           ↓
┌──────────────────────┐
│ preallocated columns │
└──────────┬───────────┘
           ↓
┌──────────────────────┐
│ 11 column tibble     │
└──────────────────────┘
```

R initiates the operation and receives the result. The repeated traversal of MARC fields and subfields happens inside compiled code.

### Bounded Parquet conversion

```text
┌──────────────────────────┐
│ MARCXML collection       │
└────────────┬─────────────┘
             ↓
┌──────────────────────────┐
│ libxml2 streaming reader │
└────────────┬─────────────┘
             ↓
┌──────────────────────────┐
│ complete MARC records    │
│ in bounded batches       │
└────────────┬─────────────┘
             ↓
┌──────────────────────────┐
│ native MARC parser in C  │
└────────────┬─────────────┘
             ↓
┌──────────────────────────┐
│ canonical rows           │
└────────────┬─────────────┘
             ↓
┌──────────────────────────┐
│ Parquet parts            │
└────────────┬─────────────┘
             ↓
┌──────────────────────────┐
│ completed dataset        │
└──────────────────────────┘
```

The same canonical schema emerges from both workflows.

## Where XML rectangling normally becomes expensive

A straightforward XML to table implementation in R can accumulate overhead in several places.

1. It may issue many repeated XPath queries. XPath is a query language for selecting nodes in an XML tree. Repeatedly asking for small sets of nodes from R is convenient, but millions of such queries can become expensive.

2. It may repeatedly switch between R and compiled C code for many tiny operations. General XML libraries are implemented largely in C, so an R call that asks for one small piece of XML often enters compiled code and then returns an R object. Each transition is cheap in isolation, but the overhead becomes visible when it happens millions of times.

3. It may serialize XML nodes to character strings.

4. It may parse those strings again as independent XML fragments.

5. It may repeatedly enlarge intermediate R vectors or data frames.

6. It may compute repeated field and repeated subfield occurrence numbers later with grouped R operations.

7. It may create parallel workers around tasks that are too small to compensate for process startup and coordination.

None of these techniques is inherently wrong. They are often excellent choices for ordinary XML work. They become expensive when multiplied by millions of MARC fields and subfields.

There are two useful ways to understand the difference.

### Workflow 1: repeated high level R and XML operations

A conventional high level implementation can let R orchestrate the parsing in many small steps.

R asks the XML library for a set of nodes, receives an R object, performs some work, asks for another set of nodes, receives another object, and continues until the record has been assembled.

Conceptually:

```text
┌──────────────────────┐
│ R code               │
└──────────┬───────────┘
           ↓
┌──────────────────────┐
│ XPath query or       │
│ XML node traversal   │
└──────────┬───────────┘
           ↓
┌──────────────────────┐
│ small result         │
│ returned to R        │
└──────────┬───────────┘
           ↓
┌──────────────────────┐
│ R reshapes, counts,  │
│ or requests more XML │
└──────────┬───────────┘
           ↓
        repeat
```

This workflow is attractive because it is expressive and easy to develop. For modest XML documents, it may be entirely appropriate.

Its weakness for catalogue scale MARC rectangling is repetition. If one record contains many fields and subfields, and a catalogue contains hundreds of thousands or millions of records, the number of small queries, temporary objects, function calls, and transitions between R and compiled XML code can become very large.

### Workflow 2: one coarse R call and native MARC traversal

The primary optimized path in `marcxmlr` moves the repeated structural work into one purpose built native parser.

R initiates the operation. Compiled C code then walks the already parsed libxml2 nodes directly, recognizes MARC elements, maintains order and occurrence counters, and fills preallocated output columns. Control returns to R when a much larger unit of useful work has been completed.

Conceptually:

```text
┌──────────────────────┐
│ R                    │
│ one parsing call     │
└──────────┬───────────┘
           ↓
┌──────────────────────┐
│ compiled C parser    │
│ traverses libxml2    │
│ nodes directly       │
└──────────┬───────────┘
           ↓
┌──────────────────────┐
│ tags, indicators,    │
│ values, order, and   │
│ occurrences handled  │
│ during traversal     │
└──────────┬───────────┘
           ↓
┌──────────────────────┐
│ preallocated         │
│ canonical columns    │
└──────────┬───────────┘
           ↓
┌──────────────────────┐
│ R tibble             │
└──────────────────────┘
```

For this particular task, the second workflow is superior because the work is highly repetitive and the desired output schema is known in advance. The package can avoid millions of small high level operations while still returning the same ordinary R data structure.

The advantage is therefore not simply that C executes individual instructions faster than R. The larger gain comes from changing the granularity of the work.

```text
Workflow 1

many small requests
      ↓
many small returned objects
      ↓
many R level transformations
      ↓
large accumulated overhead


Workflow 2

one coarse request
      ↓
one native traversal
      ↓
direct construction of canonical columns
      ↓
completed R result
```

The native path is not universally superior for every XML task. General XML tools remain more flexible for arbitrary querying and transformation. It is superior here because `marcxmlr` knows exactly which MARC structures must be preserved and can implement that repeated work as one specialized operation.

## Direct libxml2 traversal

The native parser walks libxml2 nodes directly and recognizes the small set of MARCXML structures it needs.

During traversal it extracts:

* field tags;
* indicators;
* subfield codes;
* text values;
* field order;
* subfield order; and
* occurrence information.

This work happens while the record is being traversed, rather than through a sequence of separate high level queries from R.

The structural logic therefore remains close to the parsed XML tree, while the final result remains an ordinary R tibble.

## Two pass sizing and preallocation

Repeatedly extending an output object is expensive when the final number of rows is large.

The native parser avoids that pattern by determining the required output size before filling the result vectors.

```text
┌────────────────────────────┐
│ pass 1                     │
│ inspect MARC structure     │
│ count canonical rows       │
└─────────────┬──────────────┘
              ↓
┌────────────────────────────┐
│ allocate output columns    │
│ once at final size         │
└─────────────┬──────────────┘
              ↓
┌────────────────────────────┐
│ pass 2                     │
│ traverse again and fill    │
│ the allocated columns      │
└────────────────────────────┘
```

The resulting work is predictable and avoids repeated growth and copying of large R objects.

## Occurrence bookkeeping in native code

The canonical representation requires information that is not stored directly as MARCXML attributes.

For example:

```text
Which occurrence of tag 650 is this within the record?

Which occurrence of subfield y is this within this particular 856 field?
```

A slower design can extract all values first and calculate these counters afterward with grouped R transformations.

`marcxmlr` instead maintains occurrence state while parsing.

```text
field encountered
      ↓
update field counter
      ↓
subfield encountered
      ↓
update subfield counter
      ↓
write value and counters
directly into result columns
```

Native hash based bookkeeping keeps these counters close to the traversal that creates them.

This matters because `field_occurrence` and `subfield_occurrence` are part of the data contract, not decorative metadata.

## Preserving order without reconstructing it later

MARC field order and subfield order are part of the source information.

The parser records those positions during traversal:

```text
field_order
    position of the field instance in the record

subfield_order
    position inside the containing data field
```

The optimized path therefore does not need to reconstruct source order later from tags or through a separate sort.

For multi file Parquet conversion, input files are resolved in deterministic order and global record offsets are assigned from that order. Workers may finish in a different sequence, but `record_id` does not depend on completion timing.

## Bounded native streaming

`read_marcxml()` is intentionally an in memory API. `marcxml_to_parquet()` exists because making the parser faster does not solve the memory problem created by tens of millions of output rows.

The streaming path uses libxml2 reader facilities to process complete MARC records incrementally rather than constructing one complete document tree for the full catalogue and then one enormous R result.

The complete MARC record is the unit that must remain intact.

```text
record 1
record 2
record 3
      ↓
bounded batch
      ↓
native parsing
      ↓
canonical rows
      ↓
Parquet write
      ↓
memory released
      ↓
next batch
```

A record is never split in a way that would destroy the relationships among its fields and subfields.

This gives the workflow a bounded normal working set while preserving the same schema as the in memory parser.

## Why Parquet is part of the design

For a large catalogue, parsing is only half the problem. The result also needs a representation that can be queried without immediately reading every row back into R.

```text
┌──────────────┐
│ MARCXML      │
└──────┬───────┘
       ↓
┌──────────────┐
│ marcxmlr     │
└──────┬───────┘
       ↓
┌───────────────────────┐
│ canonical Parquet     │
│ dataset               │
└──────────┬────────────┘
           ↓
┌───────────────────────┐
│ Arrow, dplyr, DuckDB, │
│ and other tools       │
└───────────────────────┘
```

The package does not need to invent a custom query language or database. Once the canonical data are on disk, they can participate in a broader analytical ecosystem.

## Why single file parallelism may lose to sequential parsing

Parallel processing has fixed costs:

```text
worker creation
      ↓
process initialization
      ↓
task scheduling
      ↓
data transfer
      ↓
result coordination
```

If the parser itself is slow, these costs may be easy to compensate for.

Once the repeated MARC traversal has moved into efficient compiled code, the balance changes. Splitting one file into many process level tasks can cost more than simply letting one process parse it rapidly from beginning to end.

That is why `workers = 1L` is the recommended starting point for a single file.

This is not an argument against parallelism. It is an argument for placing parallelism at a level where each unit of work is large enough.

## File level parallelism

A catalogue already split into independent MARCXML files provides natural coarse grained parallelism.

```text
┌────────────┐      ┌──────────────────────┐
│ file 1     │  →   │ sequential native   │
└────────────┘      │ parser               │
                    └──────────┬───────────┘
                               ↓
                         Parquet parts

┌────────────┐      ┌──────────────────────┐
│ file 2     │  →   │ sequential native   │
└────────────┘      │ parser               │
                    └──────────┬───────────┘
                               ↓
                         Parquet parts

┌────────────┐      ┌──────────────────────┐
│ file 3     │  →   │ sequential native   │
└────────────┘      │ parser               │
                    └──────────┬───────────┘
                               ↓
                         Parquet parts
```

Each worker receives a complete file and uses the optimized sequential engine internally. There is little reason for workers to exchange MARC objects with one another.

Before processing, deterministic record offsets are associated with files.

```text
ordered input files
        +
record counts
        ↓
deterministic offsets
        ↓
stable global record_id values
```

Worker completion order can vary without changing record identity.

Development tests produced byte identical Parquet output with different worker counts on the same 27 file GPO collection.

## Compatibility paths

The package retains older R and XML based paths where they are useful for compatibility, testing, or execution modes that do not use the primary native sequential engine.

They provide a valuable reference implementation, but they are not the performance target of the package.

Keeping an independently implemented path is useful during optimization because fast code can be checked against a different implementation rather than only against itself.

## Benchmark source: the GPO catalogue

The main large scale development benchmark uses the U.S. Government Publishing Office public **All CGP Records (MARC XML)** snapshot.

The February 2026 repository contains **1,115,162 MARC bibliographic records** split over **28 ZIP files**, each holding approximately 40,000 records. GPO also notes that the snapshot contains approximately 3,000 MARCXML validation errors, making it useful as real world input rather than laboratory clean input.

Repository:

<https://github.com/usgpo/cataloging-records-all-cgp-marcxml>

The benchmark figures in this README refer to the files and results used during `marcxmlr` development. GPO may refresh the repository later, so record counts and file contents should be treated as part of the benchmark specification.

## Single file benchmark

One 40,000 record GPO file produced:

```text
records:          40,000
canonical rows:   2,143,952
```

Observed elapsed times were approximately:

| Workflow | Workers | Elapsed |
|---|---:|---:|
| in memory `read_marcxml()` | 1 | 6.5 s |
| `marcxml_to_parquet()` | 1 | 8.4 s |

A minimal benchmark pattern is:

```r
library(marcxmlr)

gpo_xml <- paste0(
  "data/gpo/",
  "cataloging-records-all-cgp-XML-00.xml"
)

in_memory_time <- system.time({
  gpo <- read_marcxml(
    gpo_xml,
    workers = 1L
  )
})

stopifnot(
  dplyr::n_distinct(gpo$record_id) == 40000L,
  nrow(gpo) == 2143952L
)

in_memory_time
```

For Parquet:

```r
out <- "data/gpo/gpo_00_parquet"
stopifnot(!dir.exists(out))

parquet_time <- system.time({
  conversion <- marcxml_to_parquet(
    gpo_xml,
    output_dir = out,
    workers = 1L
  )
})

conversion
parquet_time
```

These are complete workflow timings. They include more than the inner C parser and therefore describe what a user actually experiences.

## Multi file benchmark

A development run used 27 clean GPO files:

```text
input files:       27
records:           1,080,000
canonical rows:    67,672,396
Parquet parts:     216
```

Observed elapsed times:

| Workers | Elapsed |
|---:|---:|
| 4 | about 121.7 s |
| 7 | about 99 to 100 s |

The remaining source file in the downloaded set was excluded because it contained a malformed data field without subfield elements. The strict parser behaviour was retained rather than changing the data model to make the benchmark consume every source file.

A reproducible pattern is:

```r
library(marcxmlr)

files <- sort(Sys.glob(
  "data/gpo/cataloging-records-all-cgp-XML-*.xml"
))

files <- files[seq_len(27L)]

system.time({
  conversion <- marcxml_to_parquet(
    files,
    output_dir = "data/gpo/all_clean_parquet",
    workers = 7L
  )
})

conversion
```

When reproducing benchmarks, record the exact package version, R version, libxml2 version, Arrow version, operating system, CPU, storage, input checksums, and worker count.

## Inspecting the Parquet result without materializing it

```r
library(arrow)
library(dplyr)

x <- open_dataset("data/gpo/all_clean_parquet")

x |>
  summarise(
    rows = n(),
    max_record_id = max(record_id)
  ) |>
  collect()
```

A structural audit can also check invariants such as:

* `record_id` values are contiguous;
* each record has exactly one leader when required by the input contract;
* `field_order` follows source order;
* repeated field occurrences are numbered within record and tag;
* `subfield_order` restarts for each data field instance; and
* repeated subfield codes receive distinct `subfield_occurrence` values.

Performance is useful only if these invariants remain true.

## Performance philosophy

`marcxmlr` does not gain speed by simplifying MARC semantics.

The design works in the opposite direction:

1. define the information that a faithful rectangular representation must preserve;
2. keep that representation stable;
3. move expensive implementation work underneath it into native code; and
4. stream or parallelize only where doing so does not change the data contract.

The canonical representation is the public promise. C, libxml2, batching, and worker strategy are implementation choices that can continue to improve without requiring analysts to rewrite their code.

For the ordinary R user, the result remains a tibble or an Arrow dataset. For the technically minded reader, the performance path is deliberately much closer to a purpose built MARC parser than to a long sequence of high level XML queries.

# References

* Library of Congress, [MARC standards](https://www.loc.gov/marc/).
* Library of Congress, [MARC 21 Format for Bibliographic Data: Introduction](https://www.loc.gov/marc/bibliographic/bdintro.html).
* Library of Congress, [MARCXML](https://www.loc.gov/standards/marcxml/).
* Library of Congress, [MARCXML Design Considerations](https://www.loc.gov/standards/marcxml/marcxml-design.html).
* Library of Congress, [MARCXML Architecture](https://www.loc.gov/standards/marcxml/marcxml-architecture.html).
* U.S. Government Publishing Office, [All CGP Records (MARC XML)](https://github.com/usgpo/cataloging-records-all-cgp-marcxml).
* Apache Arrow for R, [Datasets](https://arrow.apache.org/docs/r/articles/dataset.html).
* `xml2`, <https://xml2.r-lib.org/>.
* `XML`, <https://CRAN.R-project.org/package=XML>.
* `maRc`, <https://github.com/davidfuhry/maRc>.
