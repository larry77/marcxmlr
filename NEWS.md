# marcxmlr 0.2.1

* Improve portability of native parsing fallbacks by treating native
  libxml2 errors as fast-path declines and preserving the reference
  parser for public validation diagnostics.
* Improve malformed-record diagnostics by reporting the source file and
  record number, including the global `record_id` where relevant during
  multi-file Parquet conversion.

# marcxmlr 0.2.0

* Extend `marcxml_to_parquet()` to accept multiple MARCXML files and glob
  patterns such as `"catalogue/*.xml"`, producing one Parquet dataset with
  deterministic, globally contiguous `record_id` values across input files.
* Add file-level parallel processing for multi-file conversion. Complete files
  are processed independently with the optimized sequential native engine, while
  output ordering and record identifiers remain independent of worker completion
  order.
* Preserve the established single-file behaviour and worker-safe fallback paths.
  When `workers > 1` is requested for a single file, issue a periodic warning
  that the optimized sequential native parser may be faster and that users
  should benchmark their workload.


* Add a two-pass direct native libxml2 engine for sequential `read_marcxml()`:
  the first pass validates/counts records and the second fills the canonical
  11-column result directly from expanded record nodes, avoiding record XML
  serialization and reparsing. The established native-string and R parsers
  remain compatibility fallbacks.
* Add the same direct-node architecture to the default sequential
  `marcxml_to_parquet()` path, retaining bounded canonical batches and the
  existing staging-directory publication semantics. Explicit `chunk_records`
  and parallel calls continue to use the established worker-safe path.
* In development tests on the 40,000-record GPO sample (2,143,952 rows), the
  direct public `read_marcxml()` path completed in about 8.6 seconds versus
  about 27.7 seconds for the previous native path. The direct Parquet path took
  about 10.5 seconds with roughly 267 MiB peak RSS versus about 18.4 seconds and
  328 MiB for the previous bounded native path. These are machine/input-specific
  development measurements, not performance guarantees.
* Accelerate record chunks using registered C code and libxml2, applying
  xmlrectr's direct traversal, preallocation, and hashed occurrence techniques.
* Preserve both public interfaces, the canonical 11-column output, task and
  batch boundaries, and the original R parser as the compatibility fallback.
* Source installation now requires libxml2 development files. Unix
  configuration accepts `xml2-config`, `pkg-config`, or explicit
  include/library paths; Windows uses Rtools libxml2 when available and the
  established r-windows bundle fallback otherwise.
* Avoid repeated namespace discovery when validating collection children with
  a prefix-free XPath expression.
* Accelerate `marcxml_to_parquet()` with a bounded native libxml2 stream reader
  for collections that are fully inside the native parser's safe subset. The
  collection is validated before output begins; malformed or unsupported input
  falls back to the existing `XML` event-stream path and its diagnostics.
* In a development benchmark on the 40,000-record GPO sample (2,143,952 output
  rows, 5,000-record batches, sequential execution), bounded native streaming
  produced Parquet parts identical to the legacy streaming path while reducing
  elapsed time from 34.7 to 18.4 seconds and peak RSS from about 1.10 GB to
  0.33 GB. These figures describe that machine and input, not a general
  performance guarantee.

# marcxmlr 0.1.0

* Finalized the package author and copyright metadata.

* Import `stats::ave()` explicitly so package checks do not report it as an
  undefined global function.

* Added `read_marcxml()` for faithful in-memory MARCXML parsing.
* Added `marcxml_to_parquet()` for bounded-memory conversion of MARCXML
  collections to Parquet datasets.
* Added optional local parallel parsing through `future.mirai`, `futurize`,
  and `mori`.
* Made sequential execution the default for both public functions so that
  parallel process and memory use are always opt-in.
* Preserved inherited namespace declarations when serializing prefixed
  MARCXML records for independent parsing.
