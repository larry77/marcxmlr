# Experimental C4 multi-file parallel Parquet processing

## Design

This is deliberately **file-level parallelism only**, not a new mechanism for
parallelizing individual records within one file. It uses `future.mirai` and
`futurize`, as in the package's existing multi-file parallel workflow.

1. Compile the existing Expat offset helper once. Check the supported input
   encoding before scanning.
2. **In parallel across files**, screen each MARCXML source for selected byte
   positions. This returns a small index and a selected-record count per file.
3. Compute cumulative **selected** record counts in input-file order.
4. **In parallel across files**, call the already installed C4 `xmlTextReader`
   materializer for each file. Each worker writes 500-record bounded Parquet
   batches. Record IDs receive the cumulative offset for preceding files.
5. Move per-worker Parquet files into a single numbered dataset, in input order,
   and atomically publish the result directory.

No unfiltered `read_marcxml()` or `marcxml_to_parquet()` code path is altered;
no changes to the C parser are introduced. The existing Expat prototype
restrictions (uncompressed UTF-8, no DTD, standard MARCXML namespace handling)
remain. Because this is an experiment, all entry points are defined in a
standalone script under `tools/c4-offset/`, not exposed as new package APIs.

This implementation currently retains all selected byte offsets in the main R
process between screening and writing. This is bounded by the number of
selected records, **not** by `batch_records`; it should be revisited for
exceptionally large catalogues.

## Correctness smoke test

From the repository root, after `R CMD INSTALL .`:

```sh
Rscript tools/c4-offset/test-parallel-files.R .
```

The test treats the bundled 1,000-record sample as eight logical inputs;
it checks sequential and two-worker runs, full 11-column equality against
full parsing, globally consecutive record IDs and a no-match case. This is
**not** a meaningful parallel speed benchmark.

## Benchmarks: real eight-file workloads

Use eight *different* XML files (or a glob that resolves to eight files):

```sh
Rscript tools/c4-offset/benchmark-parallel-files.R c1 4 856 '/data/inputs/*.xml'
Rscript tools/c4-offset/benchmark-parallel-files.R c4 4 856 '/data/inputs/*.xml'
Rscript tools/c4-offset/benchmark-parallel-files.R c1 4 650 '/data/inputs/*.xml'
Rscript tools/c4-offset/benchmark-parallel-files.R c4 4 650 '/data/inputs/*.xml'
```

Repeat with `1` worker to establish whether parallelism is beneficial. The
C1 reference is the existing per-file C1 filtered writer, with **per-file**
record IDs; it is timed as a workload reference, NOT used as the canonical
multi-file equality oracle. C4 numbers selected records globally and
consecutively. Using C1 as reference is conservative: it does not incur a
separate record-counting phase for global renumbering.

For a quick **synthetic** functional performance comparison only (same disk
file read eight times), supply `--repeat=8` and one XML path. Results from
this configuration are not representative of eight physically separate files
or cold disk I/O.

Each command writes one CSV result into the home directory and deletes the
temporary Parquet files. Separate process runs permit measurement with
`/usr/bin/time -v`, but note that its top-level maximum RSS does not represent
**combined peak memory across independent workers**. Parallel RSS needs
per-worker observation in a subsequent test.

## Practical expectations

- Highly selective filters: C4 should avoid most of the MARC validation and
  materialization, so file-level concurrency has a good chance to help.
- Permissive filters: sequential C4 and C1 were roughly equal in earlier
  single-file experiments. **Do not assume** no parallel performance penalty:
  Expat screening, data loading and worker contention can change the result.
- Single-file filtered processing is sequential. An explicit request for
  `workers > 1` with only one resolved input file is an **error**, rather than
  silently changing the requested worker count. Use `workers = 1` for a single
  file. No separate single-file parallel scheduler is introduced.

If C4 unexpectedly falls behind C1 on permissive eight-file workloads, profile
worker contention and phase timing before changing the architecture. Do not
introduce an arbitrary selectivity cutoff as a first response.
