# marcxmlr 0.1.0.9000

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
