#!/usr/bin/env Rscript
# Research-only profiling of C4-native's previously unexplained residual.
# Usage: Rscript tools/c4-offset/profile-c4-native-residual.R FILE [REPS] [TAGS]
# TAGS: comma-separated MARC tags, default 650 (the problematic permissive case).
# Existing public unfiltered MARCXML paths are not changed.

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1L || length(args) > 3L)
  stop("Usage: Rscript profile-c4-native-residual.R FILE [REPS] [TAGS]")
input <- normalizePath(path.expand(args[[1L]]), mustWork = TRUE)
reps <- if (length(args) >= 2L) as.integer(args[[2L]]) else 5L
if (length(reps) != 1L || is.na(reps) || reps < 1L || reps > 30L)
  stop("REPS must be between 1 and 30")
tags <- if (length(args) == 3L) strsplit(args[[3L]], ",", fixed = TRUE)[[1L]] else "650"
if (!length(tags) || any(!grepl("^[0-9]{3}$", tags)))
  stop("TAGS must be comma-separated three-digit MARC tags")

script_arg <- grep("^--file=", commandArgs(FALSE), value = TRUE)
if (length(script_arg) != 1L) stop("Cannot determine script directory")
script_dir <- dirname(normalizePath(sub("^--file=", "", script_arg)))
source(file.path(script_dir, "marcxmlr-offset-test.R"), local = TRUE)
if (!requireNamespace("marcxmlr", quietly = TRUE)) stop("Install marcxmlr first")
ns <- asNamespace("marcxmlr")
C1 <- get(".prototype_read_marcxml_filtered", ns)
C4 <- get(".prototype_c4_native_read_offsets", ns)
.check_utf8(input)
indexer <- .compile_indexer(file.path(script_dir, "record_offset_index.c"))
clock <- function() unname(proc.time()[["elapsed"]])
renumber <- function(x) {
  if (nrow(x)) x$record_id <- match(x$record_id, unique(x$record_id))
  rownames(x) <- NULL
  x
}
filter_c1 <- function(tag) {
  x <- C1(input, filter_tags = tag,
          record_filter = function(screen, ids) ids %in% unique(screen$record_id))
  renumber(x)
}
scan <- function(tag) {
  out <- tempfile("c4-residual-index-", fileext = ".tsv")
  err <- tempfile("c4-residual-index-", fileext = ".log")
  on.exit(unlink(c(out, err)), add = TRUE)
  t <- clock()
  rc <- suppressWarnings(system2(
    indexer, shQuote(c(input, tag, "-", "-")), stdout = out, stderr = err
  ))
  screening_s <- clock() - t
  if (!identical(as.integer(rc), 0L))
    stop("C4 indexer failed: ", paste(readLines(err, warn = FALSE), collapse = "\n"))
  t <- clock()
  idx <- utils::read.delim(out, colClasses = c("integer", "numeric", "numeric"))
  names(idx) <- c("source_position", "start_byte", "end_byte")
  list(offsets = idx, screening_s = screening_s, index_s = clock() - t)
}

outdir <- file.path(path.expand("~"),
  paste0("marcxmlr-c4-residual-", format(Sys.time(), "%Y%m%d-%H%M%S")))
if (!dir.create(outdir)) stop("Cannot create profiling results directory")
writeLines(c(
  paste("Input:", input),
  paste("Input bytes:", file.info(input)$size),
  paste("Time:", Sys.time()),
  paste("R:", R.version.string),
  paste("marcxmlr:", as.character(utils::packageVersion("marcxmlr"))),
  paste("System:", paste(unlist(Sys.info()), collapse = " ")),
  "C1 and C4 are benchmarked in the same R process; gc() between trials.",
  "Correctness checked before timing; no Parquet benchmark or RSS measurement.",
  "C4 profiling is enabled; timings may differ slightly from uninstrumented runs.",
  "Total phase medians should not be summed; wall-clock and C clock noise apply."
), file.path(outdir, "environment.txt"))

raw <- list()
checks <- list()
set.seed(20261015L)
for (tag in tags) {
  cat("\nTag", tag, "— verifying exact canonical equality\n")
  offsets <- scan(tag)$offsets
  expected <- filter_c1(tag)
  got <- C4(input, offsets, .profile = TRUE)$canonical
  ok <- identical(got, expected)
  checks[[length(checks) + 1L]] <- data.frame(
    tag = tag, exact_equality = ok, selected_records = nrow(offsets),
    canonical_rows = nrow(got)
  )
  utils::write.csv(do.call(rbind, checks),
                   file.path(outdir, "correctness.csv"), row.names = FALSE)
  if (!ok) stop("C1 and C4-native differ for tag ", tag)
  rm(got, expected)
  gc(verbose = FALSE)
  # One warm-up of each method. Screening is not counted twice.
  invisible(filter_c1(tag))
  invisible(C4(input, offsets, .profile = TRUE))
  for (iteration in seq_len(reps)) {
    gc(verbose = FALSE)
    indexed <- scan(tag)
    result <- list()
    for (method in sample(c("C1", "C4_native"))) {
      gc(verbose = FALSE)
      t <- clock()
      if (method == "C1") {
        x <- filter_c1(tag)
        elapsed <- clock() - t
        entry <- c(c1_s = elapsed, c4_total_s = NA_real_)
      } else {
        run <- C4(input, indexed$offsets, .profile = TRUE)
        elapsed <- clock() - t
        x <- run$canonical
        native <- run$native_profile
        r <- run$r_profile
        entry <- c(
          c4_total_s = indexed$screening_s + indexed$index_s + elapsed,
          c4_scan_s = indexed$screening_s,
          c4_index_s = indexed$index_s,
          c4_materialization_s = elapsed,
          batches = run$batches,
          native,
          r,
          native_unattributed_s = r[["r_call_s"]] - sum(native),
          r_outer_overhead_s = elapsed - r[["r_total_read_s"]]
        )
      }
      if (length(unique(x$record_id)) != nrow(indexed$offsets))
        stop("Record-count mismatch in measured run")
      result[[method]] <- entry
      rm(x)
      if (method == "C4_native") rm(run)
    }
    a <- result$C1[["c1_s"]]
    b <- result$C4_native[["c4_total_s"]]
    raw[[length(raw) + 1L]] <- data.frame(tag = tag, repetition = iteration,
                                         c1_s = a, c4_s = b,
                                         c4_gain_percent = 100 * (a - b) / a,
                                         as.list(result$C4_native),
                                         check.names = FALSE)
    utils::write.csv(do.call(rbind, raw), file.path(outdir, "raw.csv"),
                     row.names = FALSE)
    cat(sprintf("  rep %d: C1 %.3f s; C4-native %.3f s (%.1f%% gain)\n",
                iteration, a, b, 100 * (a - b) / a))
  }
}

dat <- do.call(rbind, raw)
fields <- setdiff(names(dat), c("tag", "repetition", "c1_s", "c4_s",
                                "c4_gain_percent", "c4_total_s"))
# Median each measured phase across repetitions, not the sum of medians.
summary <- do.call(rbind, lapply(split(dat, dat$tag), function(d) {
  ans <- data.frame(tag = d$tag[[1L]],
    selected_records = checks[[match(d$tag[[1L]], tags)]]$selected_records,
    median_c1_s = stats::median(d$c1_s),
    median_c4_s = stats::median(d$c4_s),
    median_gain_percent = 100 * (stats::median(d$c1_s) - stats::median(d$c4_s)) /
                                    stats::median(d$c1_s))
  for (field in fields) {
    if (is.numeric(d[[field]])) ans[[paste0("median_", field)]] <- stats::median(d[[field]])
  }
  ans
}))
utils::write.csv(summary, file.path(outdir, "summary.csv"), row.names = FALSE)
cat("\nMedian totals:\n")
print(summary[c("tag", "selected_records", "median_c1_s", "median_c4_s",
                "median_gain_percent")], row.names = FALSE)
cat("\nSaved correctness.csv, raw.csv, summary.csv, environment.txt to:", outdir, "\n")
