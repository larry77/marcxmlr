#!/usr/bin/env Rscript
# Benchmark: full materialization (A) vs C1 selective screening vs C4 offsets.
# Results: correctness.csv, raw.csv, summary.csv, environment.txt, README.txt
# Usage:
#   Rscript ~/Downloads/benchmark-marcxmlr-offset-v1.R \
#     ~/marcxmlr-repro/benchmark-inputs/cataloging-records-all-cgp-XML-00.xml 5
#
# This standalone experiment does not modify marcxmlr or the input XML.
# C4 uses the current separate Expat/R proof of concept and is NOT the
# prospective integrated native implementation. Peak memory is NOT measured.

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1L || length(args) > 2L) {
  stop("Usage: Rscript benchmark-marcxmlr-offset-v1.R FILE [REPETITIONS]",
       call. = FALSE)
}
input <- normalizePath(path.expand(args[[1L]]), mustWork = TRUE)
nreps <- if (length(args) == 2L) suppressWarnings(as.integer(args[[2L]])) else 5L
if (length(nreps) != 1L || is.na(nreps) || nreps < 1L || nreps > 100L) {
  stop("REPETITIONS must be an integer from 1 to 100", call. = FALSE)
}
stopifnot(requireNamespace("marcxmlr", quietly = TRUE))

# Locate the helper next to this benchmark script, regardless of machine or home.
file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
if (length(file_arg) != 1L) stop("Please run this benchmark with Rscript.")
script_dir <- dirname(normalizePath(sub("^--file=", "", file_arg)))
script <- file.path(script_dir, "marcxmlr-offset-test.R")
if (!file.exists(script)) {
  stop("Cannot find ", script, ". Keep the offset demo in your home directory.",
       call. = FALSE)
}
source(script, local = TRUE)

pkg <- asNamespace("marcxmlr")
if (!exists(".prototype_read_marcxml_filtered", envir = pkg, inherits = FALSE)) {
  stop("The installed marcxmlr does not contain experimental C1. ",
       "Install the prototype-record-filter branch.", call. = FALSE)
}
C1 <- get(".prototype_read_marcxml_filtered", envir = pkg)

# Use same three workloads as the earlier C1 benchmarks.
scenarios <- c("856", "710", "650")

stamp <- format(Sys.time(), "%Y%m%d-%H%M%S")
outdir <- file.path(path.expand("~"), paste0("marcxmlr-offset-benchmark-", stamp))
if (!dir.create(outdir, showWarnings = FALSE)) {
  stop("Cannot create result directory: ", outdir, call. = FALSE)
}
cat("Results directory:", outdir, "\n")

writeLines(c(
  "MARCXML record filtering benchmark: A (full) / C1 / C4 (direct offsets)",
  paste("Input:", input),
  paste("File size, bytes:", file.info(input)$size),
  paste("Run date:", format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z")),
  paste("R:", R.version.string),
  paste("Platform:", R.version$platform),
  paste("marcxmlr:", as.character(utils::packageVersion("marcxmlr"))),
  paste("Operating system:", paste(unlist(Sys.info()), collapse = " | ")),
  "C4 helper: separate Expat executable compiled by the offset_test() wrapper",
  "All methods run in the SAME R process, with gc() before every timed call.",
  "The order of methods is randomized within each repetition (fixed seed).",
  "Elapsed wall clock times are measured by system.time().",
  "Peak memory is not measured; shared process peak RSS would be misleading."
), file.path(outdir, "environment.txt"))

# Every output has 11 canonical columns. The record_id is artificial,
# so normalize it to consecutive 1..N before checking table equality.
compact_ids <- function(x) {
  if (is.null(x)) return(NULL)
  if (nrow(x)) x$record_id <- match(x$record_id, unique(x$record_id))
  rownames(x) <- NULL
  x
}

record_count <- function(x) {
  if (is.null(x) || nrow(x) == 0L) return(0L)
  length(unique(x$record_id))
}

full_filtered <- function(tag) {
  full <- marcxmlr::read_marcxml(input)
  matching <- which(full$tag == tag &
                    full$field_type %in% c("datafield", "controlfield"))
  ids <- unique(full$record_id[matching])
  out <- full[full$record_id %in% ids, , drop = FALSE]
  compact_ids(out)
}

c1_filtered <- function(tag) {
  keep_tag <- function(screen_table, record_ids) {
    record_ids %in% unique(screen_table$record_id)
  }
  compact_ids(C1(input, filter_tags = tag, record_filter = keep_tag))
}

c4_filtered <- function(tag) {
  out <- offset_test(file = input, tag = tag,
                     max_records = Inf, verify = FALSE)
  list(canonical = compact_ids(out$canonical),
       matches = out$matched_total,
       screening_s = unname(out$timings[["screening_seconds"]]),
       parsing_s = unname(out$timings[["direct_seek_and_marcxmlr_seconds"]]))
}

save_rows <- function(x, filename) {
  if (length(x)) utils::write.csv(do.call(rbind, x),
                                  file.path(outdir, filename), row.names = FALSE)
}

checks <- list()
raw <- list()
set.seed(20261015L)

for (tag in scenarios) {
  cat("\n=== Tag", tag, ": correctness verification ===\n")
  # Verify true canonical equality, not just the record or row counts.
  # Avoid retaining three large canonical tables simultaneously.
  a <- full_filtered(tag)
  b <- c1_filtered(tag)
  full_equals_c1 <- identical(a, b)
  rm(a)
  gc(verbose = FALSE)
  c <- c4_filtered(tag)
  c1_equals_c4 <- identical(b, c$canonical)

  record_n <- record_count(b)
  row_n <- nrow(b)
  hits_equal <- identical(as.integer(record_n), as.integer(c$matches))
  ok <- full_equals_c1 && c1_equals_c4 && hits_equal
  checks[[length(checks) + 1L]] <- data.frame(
    tag = tag,
    full_equals_C1 = full_equals_c1,
    C1_equals_C4 = c1_equals_c4,
    index_count_equals_C1 = hits_equal,
    all_identical = ok,
    selected_records = record_n,
    canonical_rows = row_n,
    stringsAsFactors = FALSE
  )
  save_rows(checks, "correctness.csv")
  cat("Selected records:", record_n,
      "| canonical rows:", row_n,
      "| exact equality:", ok, "\n")
  rm(b, c)
  gc(verbose = FALSE)
  if (!ok) {
    stop("Correctness FAILED for tag ", tag,
         ". The saved correctness.csv identifies the discrepancy. ",
         "Benchmark aborted.", call. = FALSE)
  }

  # Warming every method once keeps compiler initialization and one-off
  # package loading outside of measured runs.
  cat("Warming A, C1, C4 ...\n")
  invisible(full_filtered(tag)); gc(verbose = FALSE)
  invisible(c1_filtered(tag)); gc(verbose = FALSE)
  invisible(c4_filtered(tag)); gc(verbose = FALSE)

  cat("Benchmarking", nreps, "repetitions for tag", tag, "...\n")
  for (rep in seq_len(nreps)) {
    for (method in sample(c("A_full", "C1", "C4_offset"))) {
      gc(verbose = FALSE)
      elapsed <- system.time({
        value <- switch(method,
          A_full = full_filtered(tag),
          C1 = c1_filtered(tag),
          C4_offset = c4_filtered(tag)
        )
      })[["elapsed"]]
      canonical <- if (identical(method, "C4_offset")) value$canonical else value
      current_records <- record_count(canonical)
      current_rows <- if (is.null(canonical)) 0L else nrow(canonical)
      # Recheck output dimensions on every measured run.
      if (current_records != record_n || current_rows != row_n) {
        stop("Output size changed: tag ", tag,
             ", method ", method, ", rep ", rep, call. = FALSE)
      }
      raw[[length(raw) + 1L]] <- data.frame(
        tag = tag,
        repetition = rep,
        method = method,
        elapsed_s = unname(elapsed),
        records = current_records,
        canonical_rows = current_rows,
        screening_s = if (identical(method, "C4_offset")) value$screening_s else NA_real_,
        selected_parse_s = if (identical(method, "C4_offset")) value$parsing_s else NA_real_,
        stringsAsFactors = FALSE
      )
      save_rows(raw, "raw.csv")
      cat(sprintf("  %s | rep %d | %.3f s\n", method, rep, elapsed))
      rm(canonical, value)
    }
  }
}

all_raw <- do.call(rbind, raw)
median_times <- stats::aggregate(elapsed_s ~ tag + method, all_raw,
                                 FUN = stats::median)
names(median_times)[names(median_times) == "elapsed_s"] <- "median_elapsed_s"
min_times <- stats::aggregate(elapsed_s ~ tag + method, all_raw, FUN = min)
max_times <- stats::aggregate(elapsed_s ~ tag + method, all_raw, FUN = max)
median_times$min_elapsed_s <- min_times$elapsed_s[match(
  paste(median_times$tag, median_times$method),
  paste(min_times$tag, min_times$method))]
median_times$max_elapsed_s <- max_times$elapsed_s[match(
  paste(median_times$tag, median_times$method),
  paste(max_times$tag, max_times$method))]

wide <- reshape(median_times[c("tag", "method", "median_elapsed_s")],
                idvar = "tag", timevar = "method", direction = "wide")
names(wide) <- sub("^median_elapsed_s\\.", "", names(wide))
wide$C4_vs_C1_speedup_x <- wide$C1 / wide$C4_offset
wide$C4_vs_C1_time_saved_pct <- 100 * (wide$C1 - wide$C4_offset) / wide$C1
wide$C4_vs_full_speedup_x <- wide$A_full / wide$C4_offset
wide$C4_vs_full_time_saved_pct <- 100 * (wide$A_full - wide$C4_offset) / wide$A_full
wide <- wide[match(scenarios, wide$tag), , drop = FALSE]
utils::write.csv(median_times, file.path(outdir, "summary_by_method.csv"), row.names = FALSE)
utils::write.csv(wide, file.path(outdir, "summary.csv"), row.names = FALSE)

writeLines(c(
  "Benchmark definition:",
  "  A_full: marcxmlr::read_marcxml(file), then retain complete records containing the tag.",
  "  C1: experimental .prototype_read_marcxml_filtered() selective two-pass reader.",
  "  C4_offset: standalone Expat indexer -> R byte seeking -> temporary XML collection -> marcxmlr::read_marcxml().",
  "  Tags: 856 (rare), 710 (intermediate), 650 (common).",
  "  Correctness: TRUE means identical() on full 11-column canonical tables, after consecutively renumbering artificial record_id.",
  "  Three comparisons (full vs C1, C1 vs C4, and index count vs C1) are checked for EACH tag before timing.",
  "  All recorded timings exclude that one-time canonical equality verification.",
  "  Each method receives one warm-up per tag. Repetition order is randomized.",
  "  Reported time gains are 100*(reference - C4)/reference, based on medians.",
  "  Positive time gain means C4 was faster. Negative time gain means slower.",
  "  C4 is a proof of concept, not an integrated native implementation.",
  "  C4 input restrictions: uncompressed UTF-8 MARCXML without DTD; fragment reconstruction assumes standard MARCXML namespace.",
  "  This run does NOT measure peak memory usage."
), file.path(outdir, "README.txt"))

cat("\n=== Correctness ===\n")
print(do.call(rbind, checks), row.names = FALSE)
cat("\n=== Median times and speedups ===\n")
print(wide, row.names = FALSE, digits = 4)
cat("\nCSV results saved in:\n", outdir, "\n", sep = "")
