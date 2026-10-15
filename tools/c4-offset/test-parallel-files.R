#!/usr/bin/env Rscript
# Small correctness test for C4 file-level parallel filtering.
# Uses eight *logical* inputs referring to one bundled 1,000-record sample.
# It is NOT a representative eight-distinct-file performance benchmark.

args <- commandArgs(trailingOnly = TRUE)
repo <- if (length(args)) normalizePath(args[[1L]], mustWork = TRUE) else
  normalizePath(".", mustWork = TRUE)
source(file.path(repo, "tools", "c4-offset", "parallel-files.R"))
if (!requireNamespace("arrow", quietly = TRUE)) stop("arrow is required")
if (!requireNamespace("marcxmlr", quietly = TRUE)) stop("marcxmlr is required")

sample <- system.file("extdata", "gpo-cgp-part00-sample.xml",
                      package = "marcxmlr")
stopifnot(nzchar(sample), file.exists(sample))
inputs <- rep(sample, 8L)
full <- marcxmlr::read_marcxml(sample)
ids <- unique(full$record_id[full$tag == "856"])
expected_one <- full[full$record_id %in% ids, , drop = FALSE]
expected_one$record_id <- match(expected_one$record_id, ids)
expected_all <- do.call(rbind, lapply(seq_along(inputs), function(i) {
  x <- as.data.frame(expected_one)
  x$record_id <- as.integer(x$record_id + (i - 1L) * length(ids))
  x
}))
rownames(expected_all) <- NULL

read_parts <- function(folder) {
  files <- sort(list.files(folder, pattern = "[.]parquet$", full.names = TRUE))
  stopifnot(length(files) > 0L)
  out <- do.call(rbind, lapply(files, function(f) {
    as.data.frame(arrow::read_parquet(f))
  }))
  rownames(out) <- NULL
  out
}

for (workers in c(1L, 2L)) {
  output <- tempfile(sprintf("c4-multi-test-%d-", workers))
  info <- .prototype_c4_multifile_to_parquet(
    files = inputs, output_dir = output,
    tag = "856", workers = workers, method = "c4",
    batch_records = 3L, allow_repeated = TRUE
  )
  got <- read_parts(output)
  if (!identical(got, expected_all)) {
    details <- all.equal(got, expected_all)
    unlink(output, recursive = TRUE, force = TRUE)
    stop("Canonical mismatch with ", workers, " workers: ",
         paste(details, collapse = "; "), call. = FALSE)
  }
  stopifnot(info$totals[["records"]] == 8L * length(ids),
            info$totals[["rows"]] == nrow(expected_all),
            identical(sort(unique(got$record_id)),
                      seq_len(8L * length(ids))))
  cat("PASS: ", workers, " worker(s), ", info$totals[["records"]],
      " records, ", nrow(got), " canonical rows, ",
      info$totals[["parquet_files"]], " parts; exact equality.\n", sep = "")
  print(round(info$timings, 3))
  unlink(output, recursive = TRUE, force = TRUE)
}

# No-match case: ensure independent empty inputs still produce valid files.
output <- tempfile("c4-multi-empty-")
info <- .prototype_c4_multifile_to_parquet(
  files = inputs, output_dir = output,
  tag = "999", workers = 2L, method = "c4", allow_repeated = TRUE
)
empty <- read_parts(output)
stopifnot(nrow(empty) == 0L, ncol(empty) == 11L,
          info$totals[["records"]] == 0L)
cat("PASS: no-match selection, canonical schema retained.\n")
unlink(output, recursive = TRUE, force = TRUE)

# Parallel filtering on a single source must fail explicitly. Testing this
# before any scan also ensures the call creates no output directory.
single_output <- tempfile("c4-single-parallel-rejected-")
single_error <- tryCatch(
  .prototype_c4_multifile_to_parquet(
    files = sample, output_dir = single_output,
    tag = "856", workers = 2L, method = "c4"
  ),
  error = identity
)
stopifnot(
  inherits(single_error, "error"),
  grepl("Parallel filtering requires at least two", conditionMessage(single_error),
        fixed = TRUE),
  !file.exists(single_output)
)
cat("PASS: filtered single-file parallel processing rejected.\n")
