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
