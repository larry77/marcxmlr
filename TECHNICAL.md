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

## Native recovery from malformed MARC records

The default parser is strict. With `on_marc_error = "skip"`, the native
recovery path identifies structurally malformed MARC records, excludes
complete records rather than individual fields, and produces an audit report.
Source-position `record_id` values are preserved, including gaps.

The recovery implementation remains native and supports both in-memory
reading and bounded-memory Parquet conversion. XML syntax and encoding
errors remain fatal; recovery does not attempt to repair invalid XML.

## Out-of-memory canonical diagnostics

`diagnose_canonical()` accepts ordinary data frames, Arrow `Dataset` objects,
and lazy Arrow queries. Arrow inputs are scanned incrementally without
collecting the complete canonical table into R memory.

Records crossing scanner batch boundaries are retained until complete.
The same structural validation rules apply to in-memory and Arrow inputs.
Arrow streams must contain complete records in non-decreasing `record_id`
order.

The function returns the same six-column diagnostics table for both input
types. Structural ambiguity is reported as an error; renumberable coordinates,
including gaps in `record_id`, may produce warnings.

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

# Performance evaluation: archived benchmarks for `marcxmlr` 0.3.1

This section reports the **2 October 2026 benchmark evidence** for `marcxmlr`
0.3.1. It evaluates concrete implementation choices: the package-specific C
parser versus a retained R/`xml2` reference implementation; complete in-memory
materialization versus batched Parquet conversion; process-level parallelism
within one XML file versus across independent files; and MARCXML reconstruction
from an Arrow Dataset. All measurements below come from the same frozen
benchmark campaign. No measurements have been extrapolated to subsequent
releases, including 0.4.0.

The intended comparison is among **ways of producing or consuming the same
canonical 11-column data**, not among alternative metadata models. The results
show performance on the specified data and computer; they are not guaranteed
throughput or memory limits on other systems.

## Input data and experimental environment

The inputs were drawn from the public U.S. Government Publishing Office (GPO)
[All CGP Records MARCXML collection](https://github.com/usgpo/cataloging-records-all-cgp-marcxml).
Three workloads were used:

| Workload | Input | Canonical rows | Purpose |
|---|---:|---:|---|
| Reference-parser subset | First 5,000 records of part 00 | 260,839 | Compare equivalent canonical outputs from the R/`xml2` reference and C parser |
| Single file | Part 00, 40,000 records | 2,143,952 | In-memory reading, Parquet conversion, within-file workers, and Arrow-backed writing |
| Multiple files | Parts 00–26, 27 files, 1,080,000 records | 67,672,396 | Conversion to Parquet with parallelism across files |

The 5,000-record subset is a **prefix**, not a random sample. Part 27 was
excluded from the multi-file workload because it contains a malformed MARC data
field without any subfield elements. The strict parser behavior was retained:
the source was not silently repaired for benchmarking. Consequently, the
multi-file results describe parts 00–26, not every file in the original GPO
collection.

Measurements were made on a **Lenovo ThinkPad P50** running Linux, with an
**Intel Core i7-6820HQ** (four physical cores, eight hardware threads),
**31.18 GiB RAM**, and a **local 512 GB SSD**. The software environment used
**`marcxmlr` 0.3.1**, **R 4.6.1**, and **Arrow 25.0.1**. The benchmark runner,
input-file checksums, software and environment information, individual
measurements, and verification outputs were retained as reproducibility
evidence. No server, cluster, or GPU was involved.

## Measurement and verification protocol

Elapsed times are **wall-clock elapsed seconds**. The parser comparison and
principal sequential and writer workflows used **five measured repetitions**;
parallel worker comparisons used **three**. Untimed warm-up runs preceded
cases for which setup or storage effects were material. Tables give the
**median**; the sequential table also gives the **interquartile range (IQR)**
to show variability within the recorded repetitions. Operating-system file
caches were **not flushed** between repetitions. These are therefore not
controlled cold-cache disk-read measurements.

Parquet conversion used **`batch_records = 5000`** and **Snappy compression**.
The parallel cases used **one, two, and four workers**, no more than the four
physical CPU cores of the benchmark machine. Timings include the work performed
by the named end-to-end workflow, not merely the isolated XML traversal phase.

For single-process in-memory reading, Parquet conversion, and Arrow-backed
writing, **peak resident set size (RSS)** was measured in fresh R processes
using GNU `/usr/bin/time -v`. Three measurements were summarized by their
median. RSS figures were **not** reported for the parallel pools: measuring the
parent R process alone would understate aggregate worker memory, and summing
per-process peaks would not necessarily describe a simultaneous peak. The
published evidence therefore does **not** establish peak RAM needs for the
multi-worker cases.

Correctness was checked independently of speed. The retained R/`xml2` reference
and compiled parser produced **exactly equal canonical tables** for the
5,000-record subset before their timings were accepted. For the writer test,
the output MARCXML was read back into the canonical representation and checked
for **exact equality of the represented canonical data**. This is a check of
MARC structure and values within the package's contract, **not** a claim of
byte-for-byte XML identity. The frozen verification results accompany the raw
measurements.

## Sequential parsing, storage, and writing

| Workflow | Workload | Median elapsed (s) | IQR (s) | Median peak RSS (MiB) |
|---|---|---:|---:|---:|
| Reference implementation in R/`xml2` | 5,000 records | 56.140 | 0.529 | Not measured |
| Package-specific compiled C parser | 5,000 records | 0.980 | 0.012 | Not measured |
| `read_marcxml()` | 40,000 records | 7.106 | 0.116 | 336.0 |
| `marcxml_to_parquet()`, one worker | 40,000 records | 9.374 | 0.015 | 277.8 |
| `write_marcxml()` from Arrow | 40,000 records | 14.493 | 0.109 | 588.2 |

**Compiled parser versus reference implementation.** On the 5,000-record
prefix, the dedicated C parser took 0.980 s rather than 56.140 s: a
**57.3-fold reduction in elapsed time** for two implementations producing an
exactly equal canonical result. This comparison isolates an important design
choice: MARC traversal, output sizing, preallocation, and occurrence bookkeeping
are performed together in a compiled operation rather than by repeated
high-level XML queries and R-level reconstruction. The reference is a
**specific retained R/`xml2` implementation**, not a claim that `marcxmlr` is
57 times faster than every possible use of `xml2` or than other MARC libraries.

**In-memory reading versus Parquet conversion.** On part 00, `read_marcxml()`
constructed the 2,143,952-row canonical table in 7.106 s. Sequential
`marcxml_to_parquet()` took 9.374 s, approximately **32% longer**, while writing
a persistent Parquet representation. Its measured peak RSS was 277.8 MiB
versus 336.0 MiB for the in-memory read, approximately **17% lower**. These
workflows do not have identical outputs: one returns a complete R tibble, while
the other produces disk-backed Parquet parts. More importantly, the latter
materializes only complete-record batches at a time, whereas the former keeps
the entire expanded table in memory. The small RSS difference on this
40,000-record case should **not** be extrapolated as a constant percentage
saving for other catalogue sizes.

**Arrow-backed MARCXML writer.** Starting from the 40,000-record canonical
Arrow Dataset, `write_marcxml()` produced MARCXML in 14.493 s with structural
checking enabled. Its measured peak RSS of 588.2 MiB was **higher** than for
either ingestion workflow in this test. The rationale for accepting an Arrow
Dataset is consequently **not** that the measured writer used less memory on
part 00. It is that complete records can be scanned, checked, and written
incrementally without first collecting the entire Dataset into one R tibble.
The test verifies structural reconstruction, not preservation of XML whitespace,
namespace-prefix spelling, or other serialization details outside the
canonical representation.

## Parallelism: the input layout matters

The benchmark distinguishes two execution regimes. For **one XML file**, worker
parallelism partitions complete records into tasks and uses a different path
from the optimized direct sequential reader. For **multiple XML files**, each
worker can process a complete file with that optimized sequential reader and
write its own Parquet parts. The logical canonical schema is unchanged in both
cases, but process startup, task preparation, coordination, and storage
contention differ.

| Input layout | Workers | Median elapsed (s) | Speedup relative to one worker |
|---|---:|---:|---:|
| One file: 40,000 records | 1 | 9.374 | 1.00 |
| One file: 40,000 records | 2 | 19.858 | 0.47 |
| One file: 40,000 records | 4 | 18.849 | 0.50 |
| 27 files: 1,080,000 records | 1 | 290.139 | 1.00 |
| 27 files: 1,080,000 records | 2 | 192.681 | 1.51 |
| 27 files: 1,080,000 records | 4 | 118.629 | 2.45 |

For **one file**, additional workers increased rather than reduced elapsed
time. Two workers took 19.858 s and four took 18.849 s, compared with 9.374 s
sequentially. The benchmark is consistent with the cost of abandoning the
direct reader path and coordinating smaller record tasks exceeding any benefit
from concurrent parsing. These observations should not be presented as a
universal statement that within-file parallelism is always slower.

For **27 independent files**, by contrast, four workers reduced elapsed time
from 290.139 s to 118.629 s, a **2.45-fold speedup** relative to the
one-worker workflow. At that setting the 27 files, containing **1,080,000
bibliographic records and 67,672,396 canonical rows**, were converted to
Parquet in just under **two minutes** on the specified laptop. The gain was
substantial but below ideal fourfold scaling: process overhead, I/O,
compression, and resource contention can all constrain concurrency. The
measurements do not disentangle the contributions of those potential limits.

The supported practical conclusion is therefore narrower and more useful than
"more workers are faster": **use the optimized sequential path as a sensible
default for a single file; consider file-level workers when the catalogue is
already divided into substantial independent MARCXML files**. The optimal
worker count remains workload- and machine-dependent.

## Interpretation, limits, and archived evidence

The figures above support four observations on the tested GPO workloads:

1. MARC-specific compiled parsing substantially reduced the cost of constructing
   the canonical table relative to the retained reference implementation.
2. Batched Parquet conversion produced a persistent canonical Dataset with
   bounded expanded-table materialization and a modest additional elapsed cost
   in the single-file test.
3. Parallelism helped across substantial input files but not within the tested
   single file.
4. Arrow-backed reconstruction avoided collecting a whole Dataset before
   writing, without showing a lower measured peak RSS on the tested workload.

The experiment was conducted on **one Linux workstation** with a specific
public corpus and fixed software versions. Record complexity, disk behavior,
cache state, compression, memory pressure, Arrow and `libxml2` versions, and
CPU topology can all change the timings. In particular, the benchmark cannot
establish an absolute upper catalogue size, a universal memory bound, a
cross-platform speed ranking, or a quantitative speedup for `marcxmlr` 0.4.0.
It also does not compare against all other MARCXML parsers.

The historical benchmark evidence is **frozen rather than regenerated for this
technical note**. The recorded results include individual timing observations,
peak-RSS observations, exact-equality verification, and derived summaries. The
reproducibility materials also document software settings, original input files
and hashes, and the benchmark runner. The input corpus and runner are referenced
at [Zenodo, DOI: 10.5281/zenodo.23160503](https://doi.org/10.5281/zenodo.23160503).
For audit purposes, the key distinction is between **recorded observations**
and values derived from them (medians, IQRs, percentage changes, and speedups).
No fresh runs, new hardware comparisons, or reconstructed measurements were
used for this revision.
