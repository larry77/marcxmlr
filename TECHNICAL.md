# Technical implementation and performance

This note explains the computational architecture and measured performance of
`marcxmlr`, complementing the canonical representation described in the main
[README](README.md). It covers the native XML readers, optional MARC-aware
record prefiltering, in-memory and Parquet workflows, Arrow-backed writing,
process-level parallelism, and reproducibility of benchmarks.

The logical data model is consistent across execution paths.
`read_marcxml()` and `marcxml_to_parquet()` produce the same **11-column
canonical representation**, whether records are selected during ingestion or
processed without a filter. The principal differences are *which complete
records* are materialized and *how much* of their canonical representation is
held in memory at once.

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

For supported ordinary **unfiltered** MARCXML, `read_marcxml()` uses a
package-specific C parser built on `libxml2`. The repeated traversal of
records, fields and subfields happens in compiled code rather than through
many small high-level XML queries from R. Optional native prefiltering takes
a separate screening path, described below, before materializing selected
records into the same canonical schema.

On the optimized path, `libxml2`'s `xmlTextReader` acts as a forward cursor over
the XML document. When the reader reaches a MARC `<record>`,
`xmlTextReaderExpand()` exposes that record subtree so that its Leader, fields
and subfields can be inspected directly. The complete XML document is therefore
not first materialized as an R object.

### Two-pass planning and exact allocation

The optimized **unfiltered** parser traverses the input twice.

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

## MARC-aware selection during XML ingestion

The `filter` argument of `read_marcxml()` and `marcxml_to_parquet()` accepts a
record-level query constructed with `marc_has()`. The query language is deliberately
small: a predicate can test a MARC `tag`, optional `subfield`, `ind1` and `ind2`,
and either a case-sensitive `equals` value or a case-sensitive, literal
`contains` substring. The familiar R operators `&`, `|` and `!` combine these
predicates, including nested Boolean expressions.

```r
q <- marc_has("650", subfield = "a", contains = "Economics") &
  marc_has("856", subfield = "u") &
  !marc_has("999")

selected <- read_marcxml("catalogue.xml", filter = q)
```

A predicate's conditions apply to **one canonical row**: for example,
`marc_has("650", subfield = "2", equals = "EUROVOC")` requires the value to
occur in subfield `2` of a `650` field. The Boolean operators, in contrast,
operate on **complete records**. In `A & B`, the matching fields may be in
separate occurrences of the same tag or in entirely different fields of one
record; the query does not assert that they belong to the same field
occurrence.

### Native single-pass screening and selected-record materialization

```text
MARC-aware query ──→ R predicate/Boolean-program compilation
                                 │
MARCXML file ──→ Expat record scan (one scan per input file)
                                 │
                      matched record byte ranges
                                 │
                   libxml2 native C4 materializer
                                 │
                      complete canonical records
                         ┌───────┴────────┐
                         ▼                ▼
                       tibble       Parquet batches
```

The R layer compiles a nested `marc_query` into a list of primitive predicates
and a compact Boolean evaluation program. The native Expat scanner traverses
the XML **once per file**; it updates predicate matches while visiting fields
and subfields, then evaluates the Boolean program at the end of each record.
For matching records it retains the original source position and start/end
byte offsets. It does **not** expand all records into canonical rows merely to
find those that match.

The selected byte ranges feed the existing native offset-based `libxml2`
materializer, which reconstructs **all canonical rows** of each selected
record. Filtering during XML ingestion assigns consecutive `record_id` values
to the selected records. The `source_position` in the intermediate offset
index preserves their position in the original XML; it is not a public
canonical column.

The original unfiltered parser and the earlier `filter_tag`, `filter_subfield`
and `filter_equals` interface are retained. The new `filter` argument cannot
be combined with those legacy arguments. The legacy filters use their own
native offset scanner; both filtered implementations share the native
selected-record materializer. This keeps the new query evaluator isolated
from the unfiltered execution paths.

The offset-based scanners require **uncompressed UTF-8 MARCXML without DTDs**
and Expat support at package build time. They do not support malformed-record
recovery, `error_report`, or `chunk_records`. These restrictions apply to
native filtering, **not automatically to the unfiltered reader**, which has
its own supported-input and recovery behavior. An unsupported filtered
configuration is rejected rather than silently sent through a different
algorithm.

### Filtered streaming and memory use

`marcxml_to_parquet(..., filter = q)` first selects matching byte ranges and
then materializes and writes those records in bounded native batches. The
working memory for the **expanded canonical rows** is limited by the active
batch, with both record-count and byte-size limits in the offset materializer.
The index of **all matching offsets**, however, is retained before batch
writing begins: its storage grows with the number of selected records. Large
individual field values and runtime/library allocations also contribute to
peak memory. The correct claim is therefore **bounded canonical-batch
materialization**, not constant end-to-end RAM consumption.

## Reusing queries after materialization

```r
canonical <- read_marcxml("catalogue.xml")
selected <- marc_filter_records(canonical, q)

# Or apply the same query lazily to a Parquet-backed Arrow Dataset:
ds <- arrow::open_dataset("catalogue_parquet")
selected_arrow <- marc_filter_records(ds, q) |>
  dplyr::collect()
```

`marc_filter_records()` identifies matching `record_id` values using `dplyr`
filters and joins, then returns **every canonical row** for those records.
With Arrow Datasets, operations remain lazy until collection; only operations
supported by the Arrow translation layer can be promised. A `record_id` must
identify one record uniquely across the **entire** materialized dataset,
including all Parquet fragments. Filtering existing canonical data preserves
the original record IDs, unlike filtered XML ingestion.

The query interface is optional. After materialization, the canonical table
also supports unrestricted ordinary R analysis, including user-written
`dplyr` pipelines and regular expressions. Arbitrary `dplyr` expressions are
**not** accepted by the native prefilter, and `marc_filter_records()` itself
accepts MARC query objects rather than arbitrary `dplyr` predicates.

## In-memory workflow

For ordinary **unfiltered** sequential use:

```r
marc <- read_marcxml("catalogue.xml")
```

The first pass plans the input; the second pass allocates the complete
canonical vectors once and fills them in source order. The R layer returns
the result as a tibble. With `filter = q`, the separate Expat screening and
native offset materializer described above instead select and reconstruct
only matching complete records.

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

The default **unfiltered** sequential path can be summarized as:

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
The filtered Parquet path described above uses the same output schema but
selects record offsets before materializing any canonical batches.

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

There are two different parallel cases for **unfiltered** ingestion;
filtered multi-file processing is described separately below.

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

### Parallel native prefiltering

For **filtered** input, file-level parallelism is the supported strategy:
each worker evaluates the same compiled MARC query against its own complete
XML file and materializes selected records into Parquet parts. The source-file
order determines the non-overlapping, consecutive global `record_id` ranges,
regardless of which worker finishes first. Sequential and parallel filtered
conversion were checked for equality across all 11 canonical columns.

A filtered **single input file with `workers > 1` is rejected deliberately**.
The fact that unfiltered single-file parallelism exists does not imply that it
uses the native prefilter or can be enabled for it. No within-file parallel
query screening or virtual splitting is part of the current implementation.

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
* failure behavior;
* sequential and parallel execution;
* record-level `marc_has()` Boolean queries, including negation and repeated
  field occurrences;
* agreement between the native query scanner and post-materialization
  tibble/Arrow selection; and
* preservation of complete canonical records across filtered in-memory,
  Parquet, and multi-file parallel workflows.

The distinction between structural and occurrence coordinates also guides
validation. Structural ambiguity is an error because a writer cannot safely
infer the intended MARC hierarchy. Stale or renumberable occurrence coordinates
can instead be warnings when `field_order` and `subfield_order` still define an
unambiguous structure.

# Performance evaluation

The following benchmarks quantify the package's **core unfiltered execution
paths**: its dedicated C parser versus a retained R/`xml2` reference;
in-memory materialization versus batched Parquet conversion; one-file and
multi-file parallelism; and reconstruction from an Arrow Dataset. These paths
remain in the current package alongside the new native filtering interface.

The measurements were recorded on **2 October 2026**, using the then-current
`marcxmlr` 0.3.1 implementation. Their relevance is architectural: the
underlying unfiltered algorithms were preserved. The numbers are **observations
from that test campaign, not a newly repeated benchmark of version 0.5.0**.
The new filtering workflow is assessed separately below.

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

## Native record selection: exploratory measurements

The C4/native-query implementation was tested separately during 0.5.0
development on the **40,000-record GPO part 00** input (2,143,952 canonical
rows). Selection and complete-record equality were checked against the
post-materialization tibble and Arrow implementations, including exact values,
substrings, indicators, `&`, `|`, `!`, and nested expressions.

These are **single development-run timings**, not the five-repetition benchmark
protocol above. They illustrate the magnitude of screening cost and the
benefits of avoiding full materialization for restrictive queries; they are
not suitable for a formal performance ranking across machines or releases.

| Ingestion scenario | Records returned | Canonical rows returned | Elapsed (s) |
|---|---:|---:|---:|
| Unfiltered `read_marcxml()` | 40,000 | 2,143,952 | 8.641 |
| Native filter: `marc_has("650")` | 34,907 | 1,899,368 | 8.721 |
| Legacy native exact match: `650$a = "Refrigeration and refrigerating machinery"` | 7 | 403 | 3.730 |
| Native compound query: `(856$u OR 650$a contains "Refriger") AND NOT 999` | 136 | 8,783 | 3.586 |
| Same compound query, Parquet streaming (one file) | 136 | 8,783 | 3.860 |

The restrictive exact-match filter ran approximately **2.3× as fast**
as that particular unfiltered run, even though the complete XML still had
to be screened. A permissive filter that selected nearly all records took
about the same time as unfiltered ingestion. Measurements were obtained from
separate executions; no confidence intervals are implied.

One additional exploratory test selected **all 40,000 records** with
`marc_has("001")` and measured peak process RSS using GNU `/usr/bin/time -v`:

| Workflow | Elapsed (s) | Peak RSS (MiB) |
|---|---:|---:|
| Filtered in-memory ingestion | 10.81 | 412.4 |
| Filtered Parquet streaming, `batch_records = 1000` | 12.55 | 274.8 |

With Parquet streaming and the same input/query, batches of 250, 1,000 and
5,000 records gave approximately **271.0, 274.8 and 334.0 MiB** peak RSS,
respectively. This is consistent with larger active batches requiring more
memory, but it **does not prove input-size-independent peak RAM**: the
selected-offset index, package/runtime overhead and individual record size
also contribute. In a separate multi-file correctness run with one 40,000-
record file and one 1,000-record file, two workers were slower than one;
uneven file sizes and worker overhead make that case unsuitable for a general
parallel-speedup claim.

## Interpretation, limits, and reproducibility

The core benchmarks and the separate filtering measurements support five
observations on the tested GPO workloads:

1. MARC-specific compiled parsing substantially reduced the cost of constructing
   the canonical table relative to the retained reference implementation.
2. Batched Parquet conversion produced a persistent canonical Dataset with
   bounded expanded-table materialization and a modest additional elapsed cost
   in the single-file test.
3. Parallelism helped across substantial input files but not within the tested
   single file.
4. Arrow-backed reconstruction avoided collecting a whole Dataset before
   writing, without showing a lower measured peak RSS on the tested workload.
5. Native record prefiltering avoided materializing most records for restrictive
   queries and reduced elapsed ingestion time in the exploratory tests, while a
   permissive filter took approximately as long as an unfiltered read. This
   fifth observation is based on development runs, not the repeated benchmark
   campaign used for the other workflows.

The main repeated benchmark campaign was conducted on **one Linux workstation**
with a specific public corpus and fixed software versions. The C4 filtering
measurements were gathered separately and are not treated as controlled
comparisons against that campaign. Record complexity, disk behavior,
cache state, compression, memory pressure, Arrow and `libxml2` versions, and
CPU topology can all change the timings. The benchmark cannot establish an
absolute upper catalogue size, a universal memory bound, a cross-platform
speed ranking, or newly measured throughput for every later release. It also
does not compare against all other MARCXML parsers.

The core unfiltered benchmark evidence is **frozen rather than regenerated
for this technical note**. Its recorded results include individual timing observations,
peak-RSS observations, exact-equality verification, and derived summaries. The
reproducibility materials also document software settings, original input files
and hashes, and the benchmark runner. The input corpus and runner are referenced
at [Zenodo, DOI: 10.5281/zenodo.23160503](https://doi.org/10.5281/zenodo.23160503).
For audit purposes, the key distinction is between **recorded observations**
and values derived from them (medians, IQRs, percentage changes, and speedups).
No retrospective recalculation or hardware comparison was used to update the
core benchmark tables. The separate C4 measurements above are explicitly
identified as later exploratory development runs.
