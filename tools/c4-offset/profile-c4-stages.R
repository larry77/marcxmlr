#!/usr/bin/env Rscript
# Disaggregate C4's elapsed time into (a) XML scan/offset selection,
# (b) reading offsets, (c) copying selected fragments into a temporary
# MARCXML collection, and (d) full marcxmlr parsing of that collection.
# Run: Rscript tools/c4-offset/profile-c4-stages.R FILE [REPETITIONS]
# No source code or input data is changed; CSV results are saved under ~.

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1L || length(args) > 2L) {
  stop("Usage: Rscript profile-c4-stages.R FILE [REPETITIONS]", call. = FALSE)
}
input <- normalizePath(path.expand(args[[1L]]), mustWork = TRUE)
nreps <- if (length(args) == 2L) suppressWarnings(as.integer(args[[2L]])) else 3L
if (length(nreps) != 1L || is.na(nreps) || nreps < 1L || nreps > 30L) {
  stop("REPETITIONS must be an integer from 1 to 30", call. = FALSE)
}
file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
if (length(file_arg) != 1L) stop("Please run this profile with Rscript.")
script_dir <- dirname(normalizePath(sub("^--file=", "", file_arg)))
source(file.path(script_dir, "marcxmlr-offset-test.R"), local = TRUE)
stopifnot(requireNamespace("marcxmlr", quietly = TRUE))
.check_utf8(input)
indexer <- .compile_indexer(file.path(script_dir, "record_offset_index.c"))

outdir <- file.path(path.expand("~"),
                    paste0("marcxmlr-c4-stage-profile-", format(Sys.time(), "%Y%m%d-%H%M%S")))
if (!dir.create(outdir, recursive = TRUE, showWarnings = FALSE)) {
  stop("Could not create directory: ", outdir, call. = FALSE)
}
writeLines(c(
  paste("File:", input),
  paste("Bytes:", file.info(input)$size),
  paste("Run:", Sys.time()),
  paste("R:", R.version.string),
  paste("marcxmlr:", as.character(utils::packageVersion("marcxmlr"))),
  "Timings: wall-clock seconds (proc.time elapsed).",
  "No extra full-catalogue reference parse or memory profiling.",
  "Each tag is measured in its own run; source-file caching can affect timings."
), file.path(outdir, "environment.txt"))

clock <- function() unname(proc.time()[["elapsed"]])
results <- list()
for (tag in c("856", "710", "650")) {
  for (rep in seq_len(nreps)) {
    gc(verbose = FALSE)
    idx_file <- tempfile("c4-index-", fileext = ".tsv")
    log_file <- tempfile("c4-index-", fileext = ".log")
    temp_xml <- tempfile("c4-selected-", fileext = ".xml")
    tryCatch({
      t0 <- clock()
      status <- suppressWarnings(system2(
        indexer,
        args = shQuote(c(input, tag, "-", "-")),
        stdout = idx_file, stderr = log_file
      ))
      t1 <- clock()
      if (!identical(as.integer(status), 0L)) {
        stop("Indexer failed: ", paste(readLines(log_file, warn = FALSE), collapse = "\n"))
      }
      hits <- utils::read.delim(idx_file,
                                colClasses = c("integer", "numeric", "numeric"))
      names(hits) <- c("source_position", "start_byte", "end_byte")
      t2 <- clock()
      if (nrow(hits)) {
        .extract_selected(input, hits, temp_xml)
        t3 <- clock()
        canonical <- marcxmlr::read_marcxml(temp_xml)
        t4 <- clock()
      } else {
        t3 <- t2
        t4 <- t2
        canonical <- NULL
      }
      records <- if (is.null(canonical)) 0L else length(unique(canonical$record_id))
      if (records != nrow(hits)) {
        stop("Selected record count disagrees with parsed output for tag ", tag)
      }
      output <- data.frame(
        tag = tag, repetition = rep,
        selected_records = nrow(hits),
        selected_source_bytes = sum(hits$end_byte - hits$start_byte),
        temporary_xml_bytes = if (file.exists(temp_xml)) file.info(temp_xml)$size else 0,
        canonical_rows = if (is.null(canonical)) 0L else nrow(canonical),
        scan_s = t1 - t0,
        read_index_s = t2 - t1,
        copy_selected_s = t3 - t2,
        parse_selected_s = t4 - t3,
        total_s = t4 - t0
      )
      results[[length(results) + 1L]] <- output
      utils::write.csv(do.call(rbind, results), file.path(outdir, "raw.csv"), row.names = FALSE)
      cat(sprintf("tag %s, rep %d: scan %.3f, index %.3f, copy %.3f, parse %.3f, total %.3f seconds\n",
                  tag, rep, output$scan_s, output$read_index_s,
                  output$copy_selected_s, output$parse_selected_s, output$total_s))
    }, finally = {
      unlink(c(idx_file, log_file, temp_xml))
    })
  }
}
raw <- do.call(rbind, results)
columns <- c("scan_s", "read_index_s", "copy_selected_s", "parse_selected_s", "total_s")
med <- stats::aggregate(raw[columns], list(tag = raw$tag), FUN = stats::median)
med$selected_records <- vapply(med$tag, function(x) raw$selected_records[match(x, raw$tag)], 0L)
med$selected_source_bytes <- vapply(med$tag, function(x) raw$selected_source_bytes[match(x, raw$tag)], 0.0)
utils::write.csv(med, file.path(outdir, "summary.csv"), row.names = FALSE)
cat("\nMedian phase timing:\n")
print(med, row.names = FALSE)
cat("\nSaved results in: ", outdir, "\n", sep = "")
