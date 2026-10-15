#!/usr/bin/env Rscript
# Experimental C4 optimization: compare DOM/readers and R/native binding
# with C1 on one machine.  Correctness is checked outside timed repetitions.
# Usage: Rscript tools/c4-offset/benchmark-c4-round2.R FILE [REPS] [TAGS]
# Default TAGS: 650. Can pass "856,710,650" for full matrix.
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1L || length(args) > 3L)
  stop("Usage: Rscript benchmark-c4-round2.R FILE [REPS] [TAGS]")
input <- normalizePath(path.expand(args[[1L]]), mustWork = TRUE)
reps <- if (length(args) >= 2L) as.integer(args[[2L]]) else 3L
if (is.na(reps) || reps < 1L || reps > 30L) stop("REPS must be 1..30")
tags <- if (length(args) == 3L) strsplit(args[[3L]], ",", fixed = TRUE)[[1L]] else "650"
if (!length(tags) || any(!grepl("^[0-9]{3}$", tags))) stop("Invalid MARC tags")
script_arg <- grep("^--file=", commandArgs(FALSE), value = TRUE)
script_dir <- dirname(normalizePath(sub("^--file=", "", script_arg[[1L]])))
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
c1 <- function(tag) {
  renumber(C1(input, filter_tags = tag, record_filter = function(screen, ids)
    ids %in% unique(screen$record_id)))
}
scan <- function(tag) {
  idx_path <- tempfile(fileext = ".tsv")
  err_path <- tempfile(fileext = ".log")
  on.exit(unlink(c(idx_path, err_path)), add = TRUE)
  start <- clock()
  status <- suppressWarnings(system2(
    indexer, shQuote(c(input, tag, "-", "-")), stdout = idx_path, stderr = err_path))
  scan_s <- clock() - start
  if (!identical(as.integer(status), 0L))
    stop("Indexer error: ", paste(readLines(err_path), collapse = "\n"))
  start <- clock()
  offsets <- utils::read.delim(idx_path, colClasses = c("integer", "numeric", "numeric"))
  names(offsets) <- c("source_position", "start_byte", "end_byte")
  list(offsets = offsets, scan_s = scan_s, index_s = clock() - start)
}

variants <- c("C1", "dom_purrr", "dom_native", "reader_purrr", "reader_native")
run_c4 <- function(method, offsets) {
  engine <- strsplit(method, "_", fixed = TRUE)[[1L]][[1L]]
  binding <- strsplit(method, "_", fixed = TRUE)[[1L]][[2L]]
  C4(input, offsets, .engine = engine, .binding = binding, .profile = TRUE)
}
output <- file.path(path.expand("~"), paste0(
  "marcxmlr-c4-round2-", format(Sys.time(), "%Y%m%d-%H%M%S")))
if (!dir.create(output)) stop("Could not create results directory")
writeLines(c(
  paste("Input:", input), paste("Input bytes:", file.info(input)$size),
  paste("Date:", Sys.time()), paste("R:", R.version.string),
  paste("marcxmlr:", as.character(utils::packageVersion("marcxmlr"))),
  paste("Host:", paste(unlist(Sys.info()), collapse = " ")),
  "C4 variants share same Expat scan cost, charged once per variant.",
  "Native reader uses per-record xmlTextReaderExpand and R vector growth.",
  "Profiler enabled; peak memory not measured; correctness checked outside timing."
), file.path(output, "environment.txt"))

results <- list(); checks <- list()
set.seed(20261015L)
for (tag in tags) {
  cat("\nTag:", tag, "\n")
  offsets <- scan(tag)$offsets
  expected <- c1(tag)
  for (method in setdiff(variants, "C1")) {
    x <- run_c4(method, offsets)$canonical
    ok <- identical(x, expected)
    checks[[length(checks) + 1L]] <- data.frame(tag = tag, method = method,
      exact_equality = ok, records = nrow(offsets), canonical_rows = nrow(x))
    utils::write.csv(do.call(rbind, checks), file.path(output, "correctness.csv"), row.names = FALSE)
    if (!ok) stop("Canonical mismatch for ", tag, " / ", method)
    rm(x); gc(FALSE)
  }
  rm(expected); gc(FALSE)
  for (method in variants) {
    if (method == "C1") invisible(c1(tag))
    else invisible(run_c4(method, offsets))
    gc(FALSE)
  }
  for (rep in seq_len(reps)) {
    indexed <- scan(tag)
    for (method in sample(variants)) {
      gc(FALSE)
      begin <- clock()
      native_read <- native_cleanup <- r_bind <- NA_real_
      if (method == "C1") {
        x <- c1(tag)
      } else {
        run <- run_c4(method, indexed$offsets)
        x <- run$canonical
        native_read <- sum(run$native_profile[c("native_xml_parse_s",
          "native_count_s", "native_allocation_s", "native_init_s", "native_write_s")])
        native_cleanup <- run$native_profile[["native_cleanup_s"]]
        r_bind <- run$r_profile[["r_bind_s"]]
      }
      elapsed <- clock() - begin
      total <- elapsed + if (method == "C1") 0 else indexed$scan_s + indexed$index_s
      if (length(unique(x$record_id)) != nrow(indexed$offsets))
        stop("Record count mismatch: ", method)
      results[[length(results) + 1L]] <- data.frame(
        tag = tag, rep = rep, method = method, total_s = total,
        materialization_s = elapsed,
        scan_s = if (method == "C1") 0 else indexed$scan_s,
        index_s = if (method == "C1") 0 else indexed$index_s,
        native_work_s = native_read,
        native_cleanup_s = native_cleanup, r_bind_s = r_bind)
      utils::write.csv(do.call(rbind, results),
                       file.path(output, "raw.csv"), row.names = FALSE)
      cat(sprintf("  %s rep %d: %.3f s\n", method, rep, total))
      rm(x)
      if (method != "C1") rm(run)
    }
  }
}
raw <- do.call(rbind, results)
summary <- do.call(rbind, lapply(split(raw, interaction(raw$tag, raw$method, drop = TRUE)),
  function(d) data.frame(tag = d$tag[[1L]], method = d$method[[1L]],
    median_total_s = stats::median(d$total_s),
    median_materialization_s = stats::median(d$materialization_s),
    median_native_cleanup_s = if (all(is.na(d$native_cleanup_s))) NA_real_ else stats::median(d$native_cleanup_s),
    median_r_bind_s = if (all(is.na(d$r_bind_s))) NA_real_ else stats::median(d$r_bind_s))))
for (tag in tags) {
  base <- summary$median_total_s[summary$tag == tag & summary$method == "C1"]
  summary$gain_over_c1_percent[summary$tag == tag] <-
    100 * (base - summary$median_total_s[summary$tag == tag]) / base
}
utils::write.csv(summary, file.path(output, "summary.csv"), row.names = FALSE)
cat("\nMedian results:\n"); print(summary, row.names = FALSE)
cat("\nFiles saved to:", output, "\n")
