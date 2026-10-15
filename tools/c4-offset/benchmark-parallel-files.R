#!/usr/bin/env Rscript
# File-level parallel comparison on the same machine. A benchmark is one
# process per configuration, NOT a statistically stable estimate from one run.
# Usage: Rscript tools/c4-offset/benchmark-parallel-files.R \
#        c4 4 856 '/data/catalogues/*.xml'
# Usage (synthetic functional load, same source read eight times):
#        Rscript tools/c4-offset/benchmark-parallel-files.R \
#        c4 4 856 --repeat=8 /data/catalogue.xml
# Compare c1/c4 at 1, 2, and 4 workers, with the same eight inputs.

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 4L || !(args[[1L]] %in% c("c1", "c4")) ||
    !grepl("^[0-9]{3}$", args[[3L]])) {
  stop("Usage: Rscript benchmark-parallel-files.R {c1|c4} WORKERS TAG FILE_OR_GLOB... [--repeat=8]",
       call. = FALSE)
}
method <- args[[1L]]
workers <- suppressWarnings(as.integer(args[[2L]]))
tag <- args[[3L]]
inputs <- args[-(1:3)]
repeat_arg <- grep("^--repeat=", inputs, value = TRUE)
if (length(repeat_arg) > 1L) stop("Only one --repeat= flag allowed")
allow_repeated <- length(repeat_arg) > 0L
if (allow_repeated) {
  if (length(inputs) != 2L) stop("--repeat=N requires exactly one FILE")
  repetitions <- suppressWarnings(as.integer(sub("^--repeat=", "", repeat_arg)))
  if (length(repetitions) != 1L || is.na(repetitions) ||
      repetitions < 2L || repetitions > 64L) stop("Choose 2 <= N <= 64")
  inputs <- rep(setdiff(inputs, repeat_arg), repetitions)
  cat("WARNING: synthetic repeated-file workload, not distinct-file I/O.\n")
}
if (length(workers) != 1L || is.na(workers) || workers < 1L)
  stop("WORKERS must be a positive integer.")
argv <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", argv[grepl("^--file=", argv)][[1L]])
source(file.path(dirname(normalizePath(script)), "parallel-files.R"))
files <- .c4_parallel_paths(inputs, allow_repeated = allow_repeated)
if (length(files) < 2L) warning("This is intended for multiple input files")
result_path <- file.path(path.expand("~"), sprintf(
  "marcxmlr-multifile-%s-%s-w%d-%s.csv", method, tag, workers,
  format(Sys.time(), "%Y%m%d-%H%M%S")
))
output <- tempfile("c4-multi-benchmark-", tmpdir = tempdir())
t0 <- proc.time()[["elapsed"]]
result <- .prototype_c4_multifile_to_parquet(
  files = files, output_dir = output, method = method, tag = tag,
  workers = workers, batch_records = 500L, allow_repeated = allow_repeated
)
elapsed <- unname(proc.time()[["elapsed"]] - t0)
summary <- data.frame(
  method = method, tag = tag, workers = result$workers,
  input_files = result$files, repeated_source = allow_repeated,
  records = as.double(result$totals[["records"]]),
  rows = as.double(result$totals[["rows"]]),
  parquet_files = as.integer(result$totals[["parquet_files"]]),
  screening_s = unname(result$timings[["screen_s"]]),
  materialize_s = unname(result$timings[["materialize_s"]]),
  consolidate_s = unname(result$timings[["consolidate_s"]]),
  total_s = elapsed, stringsAsFactors = FALSE
)
print(summary, row.names = FALSE)
utils::write.csv(summary, result_path, row.names = FALSE)
cat("Results: ", result_path, "\n", sep = "")
cat("Per-file summary:\n")
print(result$summary, row.names = FALSE)
unlink(output, recursive = TRUE, force = TRUE)
cat("Temporary Parquet output removed.\n")
