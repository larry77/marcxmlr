# Technical implementation and performance

This note is for readers who want to understand how `marcxmlr` implements and
scales the canonical MARC representation described in the main
[README](README.md). It focuses on the computational design of `marcxmlr` 0.3.1:
the compiled parser, bounded Parquet workflow, Arrow-backed writer, process-level
parallelism and benchmark methodology.

The logical data model does not change with scale. `read_marcxml()` and
`marcxml_to_parquet()` produce the same 11-column canonical representation;
the difference is how much of that representation is materialized in memory and
where it is stored.

## Architecture

### MARCXML to an in-memory tibble

```text
MARCXML file
      ↓
libxml2 forward reader
      ↓
package-specific compiled C parser
      ↓
canonical columns
      ↓
R tibble
```

For supported ordinary MARCXML, `read_marcxml()` uses a package-specific C
parser built on `libxml2`. The repeated traversal of records, fields and
subfields happens in compiled code rather than through many small high-level XML
queries from R.

On the optimized path, `libxml2`'s `xmlTextReader` acts as a forward cursor over
the XML document. When the reader reaches a MARC `<record>`,
`xmlTextReaderExpand()` exposes that record subtree so that its Leader, fields
and subfields can be inspected directly. The complete XML document is therefore
not first materialized as an R object.

### Two-pass planning and exact allocation

The compiled parser traverses the input twice.

The **first pass** is a planning pass. It checks that the document has a
supported MARCXML root and namespace and determines how many canonical rows each
selected record will produce. A Leader or control field contributes one row; a
data field contributes one row for every subfield occurrence. The plan retains
compact per-record row counts and record/row totals, not XML nodes.

The **second pass** reopens the input and traverses it again in source order.
Before a requested group of records is materialized, the planned row counts are
summed and the 11 output vectors are allocated at exactly the required size.
The parser then fills those vectors directly while it already has the MARC
structure in hand.

This design avoids several sources of overhead at once:

* repeated growth of large R objects;
* construction of a generic XML-derived intermediate representation that would
  later have to be reshaped;
* grouped R computations whose only purpose would be to reconstruct field and
  subfield occurrence counts; and
* repeated transitions between R and compiled XML code for small operations.

`field_order`, `subfield_order`, `field_occurrence` and
`subfield_occurrence` are therefore constructed while the source structure is
being traversed rather than recovered later from a less structured table.

The compiled path is deliberately conservative. Retained compatibility and
reference paths remain useful both for input outside the optimized subset and
for correctness testing against an independently implemented result.

## In-memory workflow

For ordinary sequential use:

```r
marc <- read_marcxml("catalogue.xml")
```

The first pass plans the selected input; the second pass allocates the complete
canonical vectors once and fills them in source order. The R layer then returns
the result as a tibble.

The important memory cost is the expanded canonical table itself. A MARCXML
file that is modest on disk can still produce a much larger canonical table
because each data-field subfield becomes one row and field-level context is
repeated on those rows. Subsequent filtering, grouping, joins and reshaping then
have the normal memory behavior of ordinary R objects.

## Bounded Parquet workflow

For larger collections:

```r
marcxml_to_parquet(
  "catalogue.xml",
  output_dir = "catalogue_parquet",
  batch_records = 5000L
)
```

The default sequential path can be summarized as:

```text
MARCXML
   ↓
planning pass
   ↓
complete-record canonical batches
   ↓
Parquet parts
   ↓
Arrow Dataset
```

The first pass is the same planning traversal used by the in-memory workflow.
During the second pass, however, only successive groups of complete records are
materialized. The row counts for the active group determine the exact size of
the 11 vectors needed for that batch. Arrow writes the canonical batch to a
Parquet part, after which the batch can be released before the next group is
materialized.

The working memory associated with expanded canonical data is therefore governed
primarily by the active batch rather than by the complete canonical table. This
is bounded-memory processing, not memory use that is literally constant with
catalogue size: the planning pass retains one row count per selected record, and
an unusually large individual record can itself generate a large batch of
canonical rows.

Arrow presents the physical Parquet parts as one logical Dataset:

```r
library(arrow)
library(dplyr)

catalogue <- open_dataset("catalogue_parquet")

subjects <- catalogue |>
  filter(tag == "650", subfield_code == "a") |>
  count(value, sort = TRUE)

subjects <- collect(subjects)
```

Supported filters, projections and aggregations can therefore be evaluated
against the disk-backed dataset before the reduced result is collected into R.
The physical storage strategy changes; the canonical schema does not.

## Writing canonical data as MARCXML

The writer uses the canonical representation in the opposite direction:

```text
canonical representation
      ↓
structural checks
      ↓
compiled libxml2 writer
      ↓
MARCXML collection
```

For an in-memory tibble, `write_marcxml()` checks the represented structure and
a compiled `libxml2` writer serializes complete records. Reconstruction is
governed by the structural coordinates:

* `record_id` identifies records;
* `field_order` identifies and orders fields within a record; and
* `subfield_order` orders subfields inside a data field.

`field_occurrence` and `subfield_occurrence` remain derived analytical
coordinates rather than authoritative serialization coordinates.

For an Arrow `Dataset` or lazy Arrow query, rows are scanned incrementally. If
a scanner batch ends inside one MARC record, the unfinished record is retained
and completed with rows from the next batch before it is written. Structural
checks that depend on continuity are likewise carried across batch boundaries.
The complete Dataset therefore does not have to be collected into one R tibble
merely to serialize it.

Output is staged before publication. Existing output is not silently
overwritten, and a serialization failure does not publish a partial output
family.

These checks enforce the structural contract required by `marcxmlr`; they are
not complete MARC 21 content validation or complete MARCXML schema validation.

## Parallel execution

Both `read_marcxml()` and `marcxml_to_parquet()` default to sequential
execution. This is intentional: the optimized sequential parser already moves
the repeated MARC-specific work into compiled C, so extra R processes have to
save enough work to offset process startup, scheduling, serialization and result
coordination.

There are two different parallel cases.

### Within one MARCXML file

For a single file, requesting several workers switches away from the direct
forward-reader path because live `libxml2` reader state and external pointers
cannot safely be sent to independent R worker processes. Complete MARC records
are instead represented as self-contained task inputs, split into chunks and
parsed by workers with the retained compiled record parser.

Conceptually:

```text
one XML file
    ↓
complete record tasks
    ↓
worker processes
    ↓
canonical pieces
```

This path is valid but carries additional coordination costs. Once the
sequential parser is already fast, those costs can dominate. A single file
should therefore normally be benchmarked before relying on `workers > 1L` as an
optimization.

### Across several MARCXML files

A catalogue already split across independent files provides a more natural unit
of process-level parallelism:

```text
A.xml → sequential compiled parser --+
B.xml → sequential compiled parser --+→ Parquet Dataset
C.xml → sequential compiled parser --+
```

Each worker can process one complete file with the optimized sequential parser
internally. Before parallel conversion begins, record counts are used to assign
non-overlapping global `record_id` ranges in deterministic input-file order.
Worker completion order therefore does not change logical record identity.

The practical lesson is simple: **more workers are not automatically faster**.
Parallelism is most attractive when the physical input already consists of
substantial independent files.

`write_marcxml()` deliberately has no public worker argument. Sharding output
into several MARCXML files is a physical layout choice, not parallel writing.

## Structural validation and reference implementations

Optimized native code is tested against independently implemented paths rather
than only against itself. The package retains reference/compatibility
implementations where they are useful for semantic comparison and fallback
behavior.

Tests cover cases including:

* repeated fields;
* repeated subfields;
* blank indicators and non-applicable indicators;
* source ordering;
* Unicode and XML metacharacters;
* streaming and batch boundaries;
* output sharding;
* failure behavior; and
* sequential and parallel execution.

The distinction between structural and occurrence coordinates also guides
validation. Structural ambiguity is an error because a writer cannot safely
infer the intended MARC hierarchy. Stale or renumberable occurrence coordinates
can instead be warnings when `field_order` and `subfield_order` still define an
unambiguous structure.

# Performance evaluation for marcxmlr 0.3.1

The measurements below are the final benchmark set documented for `marcxmlr`
0.3.1. They are **scale indicators, not performance guarantees**. Hardware,
storage, R, libxml2, Arrow and input complexity all affect elapsed time and
memory use.

## Benchmark data and environment

The evaluation used the public U.S. Government Publishing Office
[All CGP Records MARCXML collection](https://github.com/usgpo/cataloging-records-all-cgp-marcxml).

The main inputs were:

* a 5,000-record prefix producing 260,839 canonical rows, used for the slower
  reference-parser comparison;
* one 40,000-record file producing 2,143,952 canonical rows; and
* 27 files containing 1,080,000 records and 67,672,396 canonical rows.

The measurements were obtained with `marcxmlr` 0.3.1 under R 4.6.1 and Arrow
25.0.1 on a Lenovo ThinkPad P50 with an Intel Core i7-6820HQ, four physical
cores/eight hardware threads, 31.18 GiB RAM and a local 512 GB SSD. No server,
cluster or GPU resources were used.

Principal sequential and writer timings use five measured runs and are reported
as medians with interquartile ranges (IQR). Parallel timings use three measured
runs. Parquet conversion used `batch_records = 5000` and Snappy compression.
Peak resident set size (RSS) was measured in fresh R processes for the
single-process workflows.

## Principal sequential results

| Workflow | Input | Median elapsed (s) | IQR (s) | Peak RSS (MiB) |
|---|---:|---:|---:|---:|
| Reference R/`xml2` implementation | 5,000 records / 260,839 rows | 56.140 | 0.529 | not measured |
| Compiled C parser | 5,000 records / 260,839 rows | 0.980 | 0.012 | not measured |
| `read_marcxml()` | 40,000 records / 2,143,952 rows | 7.106 | 0.116 | 336.0 |
| `marcxml_to_parquet()` | 40,000 records / 2,143,952 rows | 9.374 | 0.015 | 277.8 |
| `write_marcxml()` from Arrow | 40,000 records / 2,143,952 rows | 14.493 | 0.109 | 588.2 |

On the 5,000-record subset, the compiled parser was 57.3 times faster than the
retained R/`xml2` reference implementation, with exact equality of the
canonical results verified before timings were accepted. This comparison is
between two implementations of the same canonical transformation, not between
different outputs.

On the full 40,000-record file, sequential Parquet conversion took about 32%
longer than the in-memory read while its measured peak RSS was about 17% lower.
The comparison should not be treated as a simple ranking: Parquet also produces
a persistent disk-backed representation and, more importantly, changes how much
expanded canonical data needs to be materialized at one time.

The Arrow-backed writer's peak RSS was higher than either single-file ingestion
workflow in this benchmark. Its scaling advantage is therefore not lower peak
RSS in this case; it is that the complete Dataset does not have to be collected
into a single R tibble before serialization.

## Parallel results

For one 40,000-record file, Parquet conversion took:

| Workers | Elapsed time (s) | Speedup vs 1 worker |
|---:|---:|---:|
| 1 | 9.374 | 1.00 |
| 2 | 19.858 | 0.47 |
| 4 | 18.849 | 0.50 |

The additional workers were slower because the task left the optimized direct
sequential path and paid worker/coordination costs.

For the 27-file corpus, conversion took:

| Workers | Elapsed time (s) | Speedup vs 1 worker |
|---:|---:|---:|
| 1 | 290.139 | 1.00 |
| 2 | 192.681 | 1.51 |
| 4 | 118.629 | 2.45 |

With four workers, 1,080,000 MARC records producing 67,672,396 canonical rows
were converted to Parquet in 118.629 seconds, just under two minutes, on the
single laptop-class machine described above.

These results support the package's separation between logical representation
and execution strategy: the canonical model remains unchanged, while compiled
parsing, bounded Parquet materialization and parallelism are applied where they
match the physical problem.

## Reproducible performance comparisons

A meaningful benchmark comparison should record at least:

* the exact `marcxmlr` version or Git commit;
* R version;
* libxml2 version;
* Arrow version where relevant;
* operating system;
* CPU;
* storage;
* exact input files or checksums; and
* worker count.

The implementation principle remains the same as in the main README: **preserve
the MARC structure first, then optimize the repeated work without changing the
canonical representation**.
