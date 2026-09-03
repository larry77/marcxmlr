# External integration benchmarks

These benchmarks are not run by `R CMD check` and require data supplied by the
user. No private catalogue is bundled with or named by the package.

The principal public integration input used during development is part `00` of
the U.S. Government Publishing Office CGP MARCXML record set. It contains
40,000 records and is available from:

<https://github.com/usgpo/cataloging-records-all-cgp-marcxml/tree/main/Record_sets>

Set `MARCXML_BENCH_FILE` to the extracted XML path and
`MARCXML_BENCH_OUTPUT` to a new output-directory path before running
`benchmark-public.R`.

The benchmark is sequential by default. Set `MARCXML_BENCH_WORKERS` explicitly
to compare parallel processing, and use a different new output directory for
each run. `MARCXML_BENCH_BATCH_RECORDS` defaults to `5000`;
`MARCXML_BENCH_CHUNK_RECORDS` is blank by default so the package chooses task
sizes automatically.

For the February 2026 snapshot used during development, part `00` produced
2,143,952 canonical rows: 40,000 leader rows, 156,999 control-field rows, and
1,946,953 data-field rows. These counts identify that snapshot and should not
be assumed for a later replacement file.
