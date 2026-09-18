# marcxmlr

[![R-CMD-check](https://github.com/larry77/marcxmlr/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/larry77/marcxmlr/actions/workflows/R-CMD-check.yaml)
[![CRAN status](https://www.r-pkg.org/badges/version/marcxmlr)](https://CRAN.R-project.org/package=marcxmlr)

`marcxmlr` reads MARC 21 XML into R **without flattening away the structure that gives MARC its meaning**. It represents leaders, control fields, data fields, indicators, repeated fields, repeated subfields, and source order in a canonical 11-column long table that works naturally with ordinary R tools.

The package provides two main workflows:

- `read_marcxml()` parses MARCXML into an in-memory tibble.
- `marcxml_to_parquet()` converts one or many MARCXML files into a bounded-memory Apache Parquet dataset that can be queried lazily.

The same canonical representation is used in both cases. Small files and catalogue-scale collections therefore have the same semantics.

## Installation

Install the CRAN release with:

```r
install.packages("marcxmlr")
```

Install the current GitHub release with:

```r
install.packages("remotes")
remotes::install_github("larry77/marcxmlr")
```

The in-memory workflow is intentionally small. The Parquet workflow uses optional dependencies including `XML` and `arrow`, and the examples below use `dplyr` for querying:

```r
install.packages(c("XML", "arrow", "dplyr"))
```

Optional parallel execution uses the packages declared in `Suggests`, including `future`, `future.mirai`, `futurize`, `furrr`, and `mori`:

```r
install.packages(c(
  "future", "future.mirai", "futurize", "furrr", "mori"
))
```

This README documents the current GitHub code. As with any R package, CRAN can briefly lag the repository between releases.

A minimal use looks like this:

```r
library(marcxmlr)

marc <- read_marcxml("records.xml")
marc
```

For a collection that should not be materialized as one R object:

```r
marcxml_to_parquet(
  "records.xml",
  output_dir = "records-parquet"
)
```

Open the resulting dataset lazily with Arrow:

```r
library(arrow)

ds <- open_dataset("records-parquet")
```

The rest of this README explains **why the representation looks the way it does**, how to query it, and—later—how the implementation makes faithful MARC rectangling fast enough for very large catalogues.

---

# Part I — Using and understanding `marcxmlr`

## Why another R package for MARCXML?

R already has excellent general XML software. `xml2` provides modern libxml2 bindings and XPath-based XML manipulation, while `XML` provides tree, XPath, event, and SAX-style facilities. There is also MARC-specific work in R: the `maRc` project, for example, exposes MARCXML records through record-oriented R6 objects.

What has been missing is a focused combination of properties aimed at **data analysis and large-scale metadata work**:

1. a documented MARC-aware rectangular representation that does not silently collapse repeated structure;
2. explicit preservation of field order, field occurrence, subfield order, subfield occurrence, and indicators;
3. the same representation for in-memory and bounded-memory ingestion;
4. direct conversion of large MARCXML collections to Parquet; and
5. an implementation designed to remain practical on millions of MARC records.

`marcxmlr` is intended to fill that particular gap. It is not a replacement for `xml2` or `XML`; in fact, those packages and libxml2 are part of the ecosystem on which this kind of work depends. Nor is the existence of `marcxmlr` a criticism of record-oriented MARC packages. The design target is different: **a faithful analytical representation of complete MARC collections in R**.

Nearby tools solve different problems:

| Tool | Main role | Difference from `marcxmlr` |
|---|---|---|
| `xml2` | General XML parsing and manipulation | Understands XML structure, not MARC field/subfield semantics or the canonical MARC table used here. |
| `XML` | General XML parsing, XPath, event and streaming interfaces | Supplies powerful low-level XML machinery, but not a MARC-specific analytical contract. |
| `maRc` | Record-oriented MARCXML access through R6 objects | Provides MARC-aware record access; `marcxmlr` instead focuses on a collection-oriented tidy representation and Parquet-scale workflows. |

The distinction is about **scope**. `marcxmlr` is deliberately narrow: MARCXML in, structurally faithful R/Parquet data out.

## Scope: what `marcxmlr` does—and does not do

`marcxmlr` is a **parser and rectangling package**. Its job is to represent the information and structure present in MARCXML faithfully enough that subsequent analysis does not have to guess what was lost during import.

It deliberately does not try to become a catalogue-management system or a MARC repair engine. In particular, it does not:

- correct malformed or semantically incorrect MARC 21 records;
- infer missing fields, indicators, or subfields;
- normalize different cataloguing practices into a common local convention;
- validate every MARC content rule or coded value;
- merge duplicate bibliographic records;
- decide which repeated values should be collapsed for a particular analysis;
- map the catalogue automatically to another metadata model such as Dublin Core or BIBFRAME; or
- replace an integrated library system.

The guiding principle is simple: **preserve first, interpret later**.

If a source record is structurally usable, `marcxmlr` aims to represent what is actually there. If the input violates assumptions required for safe parsing, failure is preferable to silently manufacturing a repaired interpretation.

This separation also keeps responsibilities clear:

```text
MARCXML parsing
      ↓
faithful canonical representation
      ↓
analysis, selection, reshaping, mapping, validation or transformation
```

`marcxmlr` concentrates on the first two layers. The third is deliberately left to ordinary R tools and to domain-specific rules chosen by the user.

## Fast enough for real catalogues

Faithfulness is only useful if it remains practical at catalogue scale. `marcxmlr` therefore moves the performance-critical parsing work into compiled C code built directly on libxml2.

A development benchmark on a public U.S. Government Publishing Office MARCXML file containing **40,000 records** produced **2,143,952 canonical rows** in approximately:

| Operation | Workers | Elapsed time |
|---|---:|---:|
| `read_marcxml()` | 1 | ~6.5 s |
| `marcxml_to_parquet()` | 1 | ~8.4 s |

A larger run over **27 GPO MARCXML files**, containing **1,080,000 records** and producing **67,672,396 canonical rows**, completed in about **100 seconds with 7 workers**.

These timings are hardware- and software-dependent; they are scale indicators, not performance guarantees. The important architectural point is that the hot path is not an R loop over millions of XML nodes. MARC traversal, output sizing, occurrence bookkeeping, and construction of the canonical result are handled in native code. Parallelism is then useful primarily where there is genuinely independent work to distribute, especially across multiple input files.

The technical implementation and reproducible benchmark patterns are documented in [Part II](#part-ii--under-the-hood-implementation-and-performance).

## What are MARC 21 and MARCXML?

MARC means **MAchine-Readable Cataloging**. MARC 21 is a family of communication formats used to represent and exchange bibliographic, authority, holdings, classification, and community information in machine-readable form.

A MARC record is not a conventional rectangular observation with one value for each variable. It is an **ordered structured record**. A bibliographic record may contain:

- a leader;
- control fields such as `001` or `008`;
- data fields such as `100`, `245`, `264`, `650`, or `856`;
- two indicators attached to each data field; and
- an ordered sequence of coded subfields within each data field.

Both fields and subfields can repeat.

MARCXML is the Library of Congress XML representation of MARC. In MARCXML, field tags and indicators are attributes, while subfields become child elements carrying their subfield code as an attribute. The MARCXML design is intended to retain MARC semantics and support lossless round-tripping between MARCXML and MARC in its ISO 2709 form.

That property is important for `marcxmlr`: a faithful analytical representation must preserve the same distinctions that make MARCXML lossless.

## Why MARC 21 is not tabular data

A tempting representation of a bibliographic record is something like:

| record_id | title | author | subject |
|---:|---|---|---|
| 1 | Nineteen eighty-four | George Orwell | Totalitarianism |

That table may be useful for a specific analysis, but it is **not a general representation of the MARC record**.

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

The values are still present, but an important relationship has disappeared: **which `$v` or `$x` belonged to which occurrence of field `650`?**

The same problem appears inside a single field when a subfield code repeats:

```text
700 1_ $a Smith, John $e editor $e translator
```

The two `$e` values are not duplicates accidentally encountered in the XML. They are two ordered occurrences of the same subfield code inside one specific `700` field instance.

A general-purpose MARC representation therefore has to preserve several levels of identity and order:

```text
record
└── field instance
    ├── field tag
    ├── indicators
    ├── position in the record
    └── ordered subfield instances
        ├── subfield code
        ├── value
        └── occurrence of that code within the field
```

This is why "one MARC record = one ordinary row" is not a safe starting assumption.

## The canonical 11-column representation

`marcxmlr` solves this by using a long, rectangular representation that **makes MARC structure explicit instead of discarding it**.

Every result contains exactly these columns, in this order:

| Column | Type | Meaning |
|---|---|---|
| `record_id` | integer | Sequential identity assigned by `marcxmlr`; distinct from MARC control field `001`. |
| `field_type` | character | `leader`, `controlfield`, or `datafield`. |
| `tag` | character | `LDR` for the leader, otherwise the MARC field tag. |
| `subfield_code` | character | MARC subfield code; `NA` for leaders and control fields. |
| `value` | character | Textual value, preserving meaningful source content. |
| `field_order` | integer | Position of the field instance in the source record; the leader is `0`. |
| `field_occurrence` | integer | Occurrence number of the same field type/tag within the record. |
| `ind1` | character | First indicator for a data field; otherwise `NA`. |
| `ind2` | character | Second indicator for a data field; otherwise `NA`. |
| `subfield_order` | integer | Position of the subfield inside its containing data field; otherwise `NA`. |
| `subfield_occurrence` | integer | Occurrence number of that subfield code inside that particular field instance; otherwise `NA`. |

### Why these columns are enough

The representation is intentionally redundant in places because the redundancy makes the structure explicit and easy to query.

- `record_id` tells us which MARC record a row belongs to.
- `field_order` identifies a **specific field instance** within that record and preserves its source position.
- `field_occurrence` makes repetition of the same tag explicit.
- `ind1` and `ind2` remain attached to the data-field instance.
- `subfield_order` preserves the order of subfields inside the field.
- `subfield_occurrence` distinguishes repeated uses of the same subfield code inside one field.

For data fields, all rows belonging to the same `record_id` + `field_order` combination belong to the same MARC field instance.

That fact is crucial. It means that a table can be rectangular without pretending that MARC itself is flat.

### Semantic equivalence, not naive flattening

MARCXML already expresses the logical MARC record without the low-level byte offsets used by ISO 2709. `marcxmlr` performs another change of representation: from XML hierarchy to explicit relational columns.

The canonical table retains the analytical information needed to distinguish:

- records;
- leaders and control fields;
- every data-field instance;
- repeated field tags;
- both indicators;
- every subfield instance;
- repeated subfield codes; and
- field and subfield order.

In other words, the MARC hierarchy is **encoded in columns rather than discarded**.

Here, *semantic equivalence* means equivalence of the MARC record structure and values represented by MARCXML, not byte-for-byte reproduction of the XML document. XML declaration details, namespace-prefix spelling, indentation, attribute ordering, comments, and other serialization details are not the analytical contract. The leader, control fields, data-field instances, indicators, subfields, repetition, and ordering are.

This is the package's central design choice. A user can always derive a simpler representation later. Information discarded during import cannot be reconstructed reliably afterward.

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

Conceptually, the canonical result is:

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

Several features are now explicit rather than hidden in XML nesting:

- both `650` fields have tag `650`, but different `field_order` and `field_occurrence` values;
- `$v Fiction.` remains attached to the correct `650` instance because the rows share the same `field_order`;
- the two `856$y` values remain two distinct subfield instances, with `subfield_occurrence` equal to `1` and `2`;
- indicators remain attached to every row belonging to their data-field instance; and
- source order is preserved at both field and subfield level.

Nothing forces the analyst to retain all of these columns forever. Their purpose is to make sure the choice to discard structural information is made **explicitly by the analyst**, not implicitly by the parser.

## Querying the canonical representation with `dplyr`

Once parsed, the result is an ordinary tibble. No special query language is required.

### Extract title statements

```r
library(dplyr)

orwell |>
  filter(tag == "245") |>
  select(record_id, subfield_code, value)
```

### Extract main subject terms

```r
orwell |>
  filter(tag == "650", subfield_code == "a") |>
  select(record_id, field_occurrence, value)
```

### Keep complete field instances when one subfield matches

This is often more useful than returning only the row that matched the condition. Group by the field instance and retain the entire group:

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
  ungroup()
```

The result contains both `$a Totalitarianism` and its associated `$v Fiction.` because they belong to the same `650` occurrence.

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
  )
```

This produces an analysis-friendly field-level view without losing the original grouping before the analyst chooses to collapse it.

### Derive a simplified table when the analysis permits it

For a particular task, you may decide that only one title and a set of subject headings matter. That is easy to derive:

```r
titles <- orwell |>
  filter(tag == "245", subfield_code == "a") |>
  transmute(record_id, title = value)

subjects <- orwell |>
  filter(tag == "650") |>
  group_by(record_id, field_order) |>
  summarise(
    subject = paste(value, collapse = " -- "),
    .groups = "drop"
  ) |>
  group_by(record_id) |>
  summarise(
    subjects = paste(subject, collapse = " | "),
    .groups = "drop"
  )

left_join(titles, subjects, by = "record_id")
```

This illustrates an important asymmetry:

> **Canonical → simplified is easy. Simplified → canonical may be impossible.**

`marcxmlr` therefore preserves structure at ingestion and lets the user decide what can safely be collapsed for a particular analytical purpose.

## Small real-world example: Library of Congress

The Library of Congress publishes a MARCXML record for Carl Sandburg's *Arithmetic*. It is a useful small real-world example because the XML and MARC structure can be inspected directly.

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
    value,
    field_order,
    subfield_order
  )
```

The point of the example is not that tag `245` is difficult to extract. It is that the exact same representation remains safe when fields and subfields repeat in much less convenient records.

## In-memory work: `read_marcxml()`

Use `read_marcxml()` when both the XML document and the parsed result fit comfortably in memory:

```r
marc <- read_marcxml(
  "records.xml",
  workers = 1L
)
```

The function accepts a MARCXML collection or a standalone record and returns the canonical 11-column tibble.

`n_max` can restrict the number of records parsed, which is useful for previews and development:

```r
preview <- read_marcxml(
  "records.xml",
  n_max = 100L
)
```

Because this workflow returns the complete result as an R object, it is the most convenient choice when the collection is reasonably sized and the next step is ordinary interactive analysis.

## Large collections: `marcxml_to_parquet()`

For larger collections, materializing tens of millions of canonical rows as one tibble may be unnecessary or undesirable. `marcxml_to_parquet()` writes the same schema as a directory of Parquet files while keeping normal working memory bounded by the configured processing batches.

Single file:

```r
marcxml_to_parquet(
  "catalogue.xml",
  output_dir = "catalogue-parquet",
  workers = 1L
)
```

Multiple files:

```r
files <- sort(Sys.glob("data/catalogue/*.xml"))

marcxml_to_parquet(
  files,
  output_dir = "catalogue-parquet",
  workers = 4L
)
```

A glob pattern can also be supplied directly when appropriate.

Open the result lazily:

```r
library(arrow)
library(dplyr)

catalogue <- open_dataset("catalogue-parquet")

catalogue |>
  filter(tag == "650", subfield_code == "a") |>
  count(value, sort = TRUE) |>
  head(20) |>
  collect()
```

`open_dataset()` does not pull the entire catalogue into an R tibble. Filters, projections, and aggregations can be pushed into Arrow before `collect()` is called.

### Global record identity across files

When several MARCXML files are converted into one dataset, `marcxmlr` assigns globally contiguous `record_id` values in deterministic input-file order. The result therefore behaves as one logical collection even when the physical source was split into many XML files.

This is independent of worker completion order: parallel execution must not change record identity.

## Parallel processing

Both public workflows default to `workers = 1L`.

For a **single MARCXML file**, start with sequential execution. The native parser is fast enough that process creation, record dispatch, serialization, and coordination can cost more than they save. `marcxml_to_parquet()` therefore warns periodically when multiple workers are requested for a single file, encouraging the user to benchmark rather than assume that more processes are faster.

Parallelism is much more attractive when a collection is naturally divided across **multiple input files**. In that case, complete files can be processed independently, with each worker using the optimized sequential parser internally.

A reasonable pattern is:

```r
workers <- max(
  1L,
  as.integer(future::availableCores()) - 1L
)

marcxml_to_parquet(
  sort(Sys.glob("data/catalogue/*.xml")),
  output_dir = "catalogue-parquet",
  workers = workers
)
```

Benchmark on the actual machine and input. XML size, average record complexity, storage speed, worker startup, Parquet compression, and memory bandwidth all influence the result.

## Memory and failure model

The two workflows deliberately have different memory guarantees:

| Function | XML ingestion | Parsed result |
|---|---|---|
| `read_marcxml()` | Builds the document needed for in-memory parsing | Complete canonical tibble is returned in memory |
| `marcxml_to_parquet()` | Processes complete records incrementally | Canonical rows are written to Parquet parts; only a summary is returned |

Bounded memory does **not** mean constant memory. An unusually large individual record still has to be represented while it is being processed, and multiple workers naturally increase concurrent memory use.

For Parquet conversion, output is first written under a staging directory. The requested dataset directory is published only after successful conversion, and an existing output directory is not silently overwritten. This reduces the risk of mistaking a partially written dataset for a complete one.

---

# Part II — Under the hood: implementation and performance

Everything above is sufficient to use `marcxmlr` correctly. This part is for readers who want to understand why the package can preserve a comparatively rich MARC representation without paying the usual price of millions of high-level XML operations in R.

The short answer is: **the expensive loops are not R loops**.

The package keeps the public interface small and R-native, while moving the hot parsing path into compiled C code using libxml2 directly.

## Architectural overview

The in-memory path can be thought of as:

```text
MARCXML file
    ↓
libxml2 document
    ↓
native MARC traversal in C
    ↓
pre-sized canonical columns
    ↓
11-column tibble
```

The bounded-memory Parquet path is different at the ingestion boundary:

```text
MARCXML collection(s)
    ↓
libxml2 streaming reader
    ↓
complete MARC records / bounded batches
    ↓
native MARC parser in C
    ↓
canonical rows
    ↓
Parquet parts
    ↓
completed Arrow dataset
```

The same canonical schema emerges from both paths.

## Where XML rectangling normally becomes expensive

A straightforward XML-to-table implementation in R can accumulate overhead in several places:

1. repeated XPath evaluation or high-level node traversal;
2. crossing the R/C boundary for many small operations;
3. serializing XML nodes to character strings;
4. reparsing those strings as independent XML fragments;
5. repeatedly growing intermediate R vectors or data frames;
6. computing repeated-field and repeated-subfield occurrence numbers afterward with grouped R operations; and
7. creating parallel workers around work units that have become too small to amortize process overhead.

None of these operations is intrinsically wrong. They are often ideal for ordinary XML tasks. They become expensive when multiplied by millions of MARC fields and subfields.

`marcxmlr` is optimized around the fact that MARCXML has a small and predictable structural vocabulary: records contain a leader, control fields, and data fields; data fields contain ordered subfields. The parser does not need a general-purpose transformation language for the hot loop.

## Direct libxml2 traversal

The native parser walks libxml2 nodes directly and recognizes the MARCXML structures it needs. Field tags, indicators, subfield codes, text values, and source order are extracted while traversing the record rather than through repeated R-level queries.

This has two consequences:

- the structural logic stays close to the underlying XML representation; and
- far fewer temporary R objects are needed during extraction.

The result is still an ordinary R tibble. C is an implementation detail, not a new user-facing data model.

## Two-pass sizing and preallocation

One of the most expensive patterns in high-volume rectangling is repeatedly extending an output object while the final number of rows is still unknown.

The native parser avoids that pattern by determining the required output size before filling the result vectors. Once the number of canonical rows is known, the output columns can be allocated at their target size and populated directly.

Conceptually:

```text
pass 1: inspect structure → determine canonical row count
pass 2: traverse structure → fill preallocated columns
```

This turns output construction into predictable linear work rather than repeated allocation and copying.

## Occurrence bookkeeping in native code

The canonical representation requires information that is not directly stored as explicit MARCXML attributes:

- which occurrence of tag `650` is this within the record?
- which occurrence of subfield `$y` is this within this particular `856` field?

A naive implementation can extract all values first and compute these counters later with grouped R transformations. `marcxmlr` instead maintains the required occurrence state while parsing.

The parser therefore emits values such as `field_occurrence` and `subfield_occurrence` as part of construction of the canonical table rather than as a large post-processing step. Native hash-based bookkeeping keeps these counters close to the traversal that creates them instead of requiring a second large grouped pass in R.

This matters because these columns are not cosmetic metadata. They are part of what makes the rectangular representation faithful to repeated MARC structure.

## Preserving order without sorting the result afterward

MARC field order and subfield order are semantic source information. The parser records those positions during traversal:

```text
field_order       = position of the field instance in the record
subfield_order    = position inside the containing data field
```

The optimized path therefore does not need to reconstruct source order later by guessing from tags or by imposing a lexical sort.

For multi-file Parquet conversion, input files are resolved in deterministic order and global record offsets are assigned from that order. Workers may finish in a different sequence, but `record_id` does not depend on completion timing.

## Bounded native streaming

`read_marcxml()` is intentionally an in-memory API. `marcxml_to_parquet()` exists because simply making the parser faster does not solve the memory problem of a result containing tens of millions of rows.

The streaming path uses libxml2's reader facilities to process complete MARC records incrementally rather than building one DOM for the entire catalogue and then constructing one enormous R object.

The important unit is the **complete record**. A MARC record is never split in a way that would destroy the relationships among its fields and subfields. Records are accumulated into bounded work batches, transformed into canonical rows, written to Parquet, and then released before later batches are processed.

This gives the workflow a bounded normal working set while preserving the exact same schema as the in-memory parser.

## Why Parquet is part of the design

For a large catalogue, parsing is only half the problem. The result also needs a representation that can be queried without immediately reading every canonical row back into R.

Parquet and Arrow provide that second half:

```text
MARCXML
   ↓
marcxmlr
   ↓
canonical Parquet dataset
   ↓
Arrow / dplyr / DuckDB / other analytical tooling
```

The parser therefore does not need to invent a package-specific database or query language. Once the canonical data are on disk, they participate in a much broader analytical ecosystem.

## Why single-file parallelism may lose to sequential parsing

Parallel XML parsing sounds attractive, but parallelism has fixed costs:

```text
worker creation
+ process initialization
+ task scheduling
+ data transfer / serialization
+ result coordination
```

If the sequential parser itself is slow, these costs may be easy to amortize. Once the hot path has been moved into efficient native code, the balance changes. Splitting one file into many process-level tasks can cost more than simply letting one process parse it rapidly from beginning to end.

That is why `workers = 1L` is the recommended starting point for a single file.

This is not an argument against parallelism. It is an argument for placing parallelism at a level where the work units are large enough.

## File-level parallelism

A catalogue already split into independent MARCXML files provides natural coarse-grained parallelism:

```text
file 1 ──→ native sequential parser ──→ Parquet parts
file 2 ──→ native sequential parser ──→ Parquet parts
file 3 ──→ native sequential parser ──→ Parquet parts
file 4 ──→ native sequential parser ──→ Parquet parts
```

Each worker receives a complete file and uses the optimized sequential engine internally. There is little reason for workers to exchange MARC objects with one another. In multi-file mode the file is deliberately the unit of parallel work; `chunk_records` is rejected rather than mixing file-level and within-file scheduling strategies.

Before processing, deterministic record offsets are associated with files. As a result:

```text
same ordered inputs
        +
same MARC records
        ↓
same global record_id values
```

regardless of which worker finishes first.

This design produced byte-identical Parquet output in development tests using different worker counts on the same 27-file GPO collection.

## Compatibility paths

The package retains older R/XML-based paths where they are useful for compatibility, testing, or execution modes that do not use the primary native sequential engine. They provide an important reference implementation, but they are not the performance target of the package.

Keeping a less optimized path is also valuable during development: performance work can be checked against an independently implemented representation instead of merely checking that fast code agrees with itself.

## Benchmark source: the GPO catalogue

The main large-scale development benchmark uses the U.S. Government Publishing Office's public **All CGP Records (MARC XML)** snapshot.

The February 2026 repository contains **1,115,162 MARC bibliographic records** split over **28 ZIP files**, each holding approximately 40,000 records. GPO also notes that the snapshot contains approximately 3,000 MARCXML validation errors, making it useful as real-world rather than laboratory-clean input.

Repository:

<https://github.com/usgpo/cataloging-records-all-cgp-marcxml>

The benchmark figures in this README refer to the files and results used during `marcxmlr` development. GPO may refresh the repository later, so record counts and file contents should be treated as part of the benchmark specification rather than timeless properties of the source.

## Single-file benchmark

One 40,000-record GPO file produced:

```text
records:          40,000
canonical rows:   2,143,952
```

Observed elapsed times in the development benchmark were approximately:

| Workflow | Workers | Elapsed |
|---|---:|---:|
| in-memory `read_marcxml()` | 1 | 6.5 s |
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
out <- "data/gpo/gpo-00-parquet"
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

These are end-to-end timings. They include more than just the inner C parser and are therefore more useful to users than microbenchmarks of isolated functions.

## Multi-file benchmark

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
| 4 | ~121.7 s |
| 7 | ~99–100 s |

The remaining source file in the downloaded set was excluded from this benchmark because it contained a malformed data field without subfield elements. The parser's strict behaviour was retained rather than changing the data model merely to make the benchmark consume every source file.

A reproducible pattern is:

```r
library(marcxmlr)

files <- sort(Sys.glob(
  "data/gpo/cataloging-records-all-cgp-XML-*.xml"
))

# Use the exact clean set intended for the benchmark.
files <- files[seq_len(27L)]

system.time({
  conversion <- marcxml_to_parquet(
    files,
    output_dir = "data/gpo/all-clean-parquet",
    workers = 7L
  )
})

conversion
```

When reproducing benchmarks, record the exact package version, R version, libxml2 version, Arrow version, operating system, CPU, storage, input checksums, and worker count. Without that information, elapsed times are anecdotes rather than benchmarks.

## Inspecting the Parquet result without materializing it

```r
library(arrow)
library(dplyr)

x <- open_dataset("data/gpo/all-clean-parquet")

x |>
  summarise(
    rows = n(),
    max_record_id = max(record_id)
  ) |>
  collect()
```

A structural audit can also check invariants such as:

- `record_id` values are contiguous;
- each record has exactly one leader when required by the input contract;
- `field_order` increases according to source order;
- repeated field occurrences are numbered within record and tag;
- subfield order restarts for each data-field instance; and
- repeated subfield codes receive distinct `subfield_occurrence` values.

Performance is useful only if these invariants remain true.

## Performance philosophy

`marcxmlr` does not try to gain speed by simplifying MARC semantics. The design works in the opposite direction:

1. define the information that a faithful rectangular representation must preserve;
2. keep that representation stable;
3. move the expensive implementation work underneath it into native code; and
4. stream or parallelize only where doing so does not change the data contract.

That separation is important. The canonical representation is the public promise; C, libxml2, batching, and worker strategy are implementation choices that can continue to improve without requiring analysts to rewrite their code.

For the ordinary R user, the result is still just a tibble or an Arrow dataset. For the technically minded reader, the performance path is deliberately much closer to a purpose-built MARC parser than to a loop of high-level XML queries.

---

# References

- Library of Congress, [MARC standards](https://www.loc.gov/marc/).
- Library of Congress, [MARC 21 Format for Bibliographic Data: Introduction](https://www.loc.gov/marc/bibliographic/bdintro.html).
- Library of Congress, [MARCXML](https://www.loc.gov/standards/marcxml/).
- Library of Congress, [MARCXML Design Considerations](https://www.loc.gov/standards/marcxml/marcxml-design.html).
- Library of Congress, [MARCXML Architecture](https://www.loc.gov/standards/marcxml/marcxml-architecture.html).
- U.S. Government Publishing Office, [All CGP Records (MARC XML)](https://github.com/usgpo/cataloging-records-all-cgp-marcxml).
- Apache Arrow for R, [Datasets](https://arrow.apache.org/docs/r/articles/dataset.html).
- `xml2`, <https://xml2.r-lib.org/>.
- `XML`, <https://CRAN.R-project.org/package=XML>.
- `maRc`, <https://github.com/davidfuhry/maRc>.

