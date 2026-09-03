library(marcxmlr)

input <- Sys.getenv("MARCXML_BENCH_FILE", unset = "")
output <- Sys.getenv("MARCXML_BENCH_OUTPUT", unset = "")
workers <- as.integer(Sys.getenv("MARCXML_BENCH_WORKERS", unset = "1"))
batch_records <- as.integer(Sys.getenv(
  "MARCXML_BENCH_BATCH_RECORDS",
  unset = "5000"
))
chunk_text <- Sys.getenv("MARCXML_BENCH_CHUNK_RECORDS", unset = "")
chunk_records <- if (nzchar(chunk_text)) as.integer(chunk_text) else NULL

if (!nzchar(input) || !file.exists(input)) {
  stop("Set MARCXML_BENCH_FILE to an existing public MARCXML collection.")
}

if (!nzchar(output)) {
  stop("Set MARCXML_BENCH_OUTPUT to a new dataset-directory path.")
}

if (is.na(workers) || workers < 1L) {
  stop("MARCXML_BENCH_WORKERS must be a positive integer.")
}

if (is.na(batch_records) || batch_records < 1L) {
  stop("MARCXML_BENCH_BATCH_RECORDS must be a positive integer.")
}

if (!is.null(chunk_records) &&
    (is.na(chunk_records) || chunk_records < 1L)) {
  stop("MARCXML_BENCH_CHUNK_RECORDS must be blank or a positive integer.")
}

print(list(
  input = normalizePath(input),
  output = output,
  workers = workers,
  batch_records = batch_records,
  chunk_records = chunk_records
))

timing <- system.time({
  result <- marcxml_to_parquet(
    input,
    output_dir = output,
    batch_records = batch_records,
    workers = workers,
    chunk_records = chunk_records
  )
})

print(timing)
print(result)
