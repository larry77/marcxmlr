#!/usr/bin/env Rscript
# Experimental Phase Profile, first iteration. Linux only.
# Run after R CMD INSTALL . from the experimental branch.
# Usage: Rscript tools/profile-filter-stage3.R /path/to/collection.xml [repetitions]
# Output: ~/marcxmlr-filter-profile-YYYYMMDD-HHMMSS/{raw,summary}.csv
# Profiled timings INCLUDE native clock and R instrumentation overhead; they
# should not be compared directly with uninstrumented stage 1/2 timings.

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1L || length(args) > 2L) {
  stop("Usage: Rscript tools/profile-filter-stage3.R INPUT.xml [repetitions]")
}
file <- normalizePath(path.expand(args[[1L]]), mustWork = TRUE)
repetitions <- if (length(args) == 2L) as.integer(args[[2L]]) else 3L
if (length(repetitions) != 1L || is.na(repetitions) || repetitions < 1L) {
  stop("repetitions must be a positive integer")
}
if (!file.exists("/proc/self/status")) stop("Linux is required")
suppressPackageStartupMessages(library(marcxmlr))

cases <- c(rare_856 = "856", intermediate_710 = "710", common_650 = "650")
filter_for_tag <- function(tag) {
  force(tag)
  function(x, record_ids) record_ids %in% unique(x$record_id)
}

# Correctness: full materialization and post-filtering must agree with the
# selectively screened result, including record IDs, all 11 columns and order.
cat("Checking exact equality on: ", file, "\n", sep = "")
full <- marcxmlr::read_marcxml(file)
for (case in names(cases)) {
  tag <- cases[[case]]
  ids <- unique(full$record_id[full$tag == tag])
  expected <- full[full$record_id %in% ids, , drop = FALSE]
  observed <- marcxmlr:::.prototype_read_marcxml_filtered(
    file, filter_tags = tag, record_filter = filter_for_tag(tag)
  )
  if (!identical(expected, observed)) stop("Output mismatch: ", case)
  cat(sprintf("  %-18s %6d records, %7d canonical rows: identical\n",
              case, length(ids), nrow(observed)))
}
rm(full, expected, observed)
invisible(gc())

outdir <- file.path(path.expand("~"), paste0("marcxmlr-filter-profile-",
                                            format(Sys.time(), "%Y%m%d-%H%M%S")))
if (!dir.create(outdir)) stop("Cannot create: ", outdir)
rows <- list()
for (case in names(cases)) {
  tag <- cases[[case]]
  for (i in seq_len(repetitions)) {
    invisible(gc())
    prof <- marcxmlr:::.prototype_profile_marcxml_filtered(
      file, filter_tags = tag, record_filter = filter_for_tag(tag),
      screen_batch_records = 1000L, batch_records = 5000L
    )
    row <- data.frame(case = case, repetition = i,
                      as.list(c(prof$timings, prof$counts)),
                      check.names = FALSE)
    rows[[length(rows) + 1L]] <- row
    cat(sprintf("%-18s rep %d: total %.3f s; screen native %.3f s; second native %.3f s\n",
                case, i, prof$timings[["total_s"]],
                prof$timings[["screen_native_s"]],
                prof$timings[["second_native_s"]]))
    rm(prof)
  }
}
raw <- do.call(rbind, rows)
utils::write.csv(raw, file.path(outdir, "raw.csv"), row.names = FALSE)
num <- setdiff(names(raw), c("case", "repetition"))
summary <- do.call(rbind, lapply(split(raw, raw$case), function(x) {
  data.frame(case = x$case[[1L]],
             as.list(vapply(x[num], stats::median, numeric(1))),
             check.names = FALSE)
}))
rownames(summary) <- NULL
utils::write.csv(summary, file.path(outdir, "summary.csv"), row.names = FALSE)
cat("\nMedian phase timings (seconds; nested times, do not sum all columns):\n")
print(summary[c("case", "total_s", "plan_and_screen_s", "screen_native_s",
                "screen_validate_s", "screen_extract_s", "screen_pack_s",
                "r_filter_callback_s", "second_native_s",
                "second_revalidate_s", "second_write_s", "bind_s")],
      row.names = FALSE, digits = 3)
cat("\nWrote raw.csv and summary.csv in: ", outdir, "\n", sep = "")
