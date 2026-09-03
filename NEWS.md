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
