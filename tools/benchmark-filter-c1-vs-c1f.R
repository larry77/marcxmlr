#!/usr/bin/env Rscript
# Experimental comparison of existing C1 against strict fused C1-F.
# One warmup per case/method, then alternating measured runs on the same machine.
# No package API is changed and no historical benchmark is overwritten.
args <- commandArgs(trailingOnly = TRUE)
if (!length(args) || !file.exists(args[[1L]])) {
  stop("Usage: Rscript tools/benchmark-filter-c1-vs-c1f.R FILE.xml [repetitions]",
       call. = FALSE)
}
file <- normalizePath(args[[1L]], mustWork = TRUE)
reps <- if (length(args) >= 2L) as.integer(args[[2L]]) else 5L
if (is.na(reps) || reps < 1L) stop("repetitions must be positive", call. = FALSE)
library(marcxmlr)

cases <- list(rare_856 = "856", intermediate_710 = "710", common_650 = "650")
keep <- function(x, record_ids) record_ids %in% unique(x$record_id)
run_one <- function(tag, fused) {
  marcxmlr:::.prototype_read_marcxml_filtered(
    file, filter_tags = tag, record_filter = keep,
    screen_batch_records = 1000L, .fused = fused
  )
}

raw <- list()
for (case in names(cases)) {
  tag <- cases[[case]]
  cat("\nChecking equality:", case, "\n")
  baseline <- run_one(tag, FALSE)
  optimized <- run_one(tag, TRUE)
  stopifnot(identical(baseline, optimized))
  cat("Selected records:", length(unique(baseline$record_id)),
      " rows:", nrow(baseline), "\n")
  rm(baseline, optimized); invisible(gc())

  # Deliberately warm both paths without recording the time.
  invisible(run_one(tag, FALSE)); invisible(run_one(tag, TRUE)); invisible(gc())
  for (i in seq_len(reps)) {
    # Alternate order to reduce cache and thermal ordering effects.
    orders <- if (i %% 2L) c(FALSE, TRUE) else c(TRUE, FALSE)
    for (fused in orders) {
      invisible(gc())
      elapsed <- system.time({
        result <- run_one(tag, fused)
        rows <- nrow(result)
        records <- length(unique(result$record_id))
      })[["elapsed"]]
      method <- if (fused) "c1_fused" else "c1_original"
      raw[[length(raw) + 1L]] <- data.frame(
        case = case, method = method, run = i,
        elapsed_s = elapsed, selected_records = records, selected_rows = rows
      )
      cat(sprintf("%s %s run %d: %.3f s\n", case, method, i, elapsed))
      rm(result)
    }
  }
}

out <- do.call(rbind, raw)
summary <- aggregate(elapsed_s ~ case + method, out, median)
names(summary)[3] <- "median_elapsed_s"
summary$iqr_elapsed_s <- vapply(seq_len(nrow(summary)), function(i) {
  x <- out$elapsed_s[out$case == summary$case[i] &
                     out$method == summary$method[i]]
  IQR(x)
}, numeric(1))
summary <- summary[order(summary$case, summary$method), ]

# Run one opt-in instrumented profile for each method/case. This is kept
# outside the elapsed-time results, since instrumentation adds overhead.
profile <- list()
for (case in names(cases)) {
  for (fused in c(FALSE, TRUE)) {
    p <- marcxmlr:::.prototype_profile_marcxml_filtered(
      file, cases[[case]], keep, screen_batch_records = 1000L,
      .fused = fused
    )
    v <- p$timings
    profile[[length(profile) + 1L]] <- data.frame(
      case = case,
      method = if (fused) "c1_fused" else "c1_original",
      total_s = unname(v[["total_s"]]),
      screen_native_s = unname(v[["screen_native_s"]]),
      # In the fused path this includes extraction; do not interpret
      # screen_extract_s alone as the true screening cost.
      screen_validate_and_extract_s = unname(v[["screen_validate_s"]]) +
        unname(v[["screen_extract_s"]]),
      second_native_s = unname(v[["second_native_s"]])
    )
    rm(p)
  }
}

output_dir <- file.path(path.expand("~"), paste0(
  "marcxmlr-fused-c1-", format(Sys.time(), "%Y%m%d-%H%M%S")
))
if (!dir.create(output_dir)) stop("Could not create output directory")
write.csv(out, file.path(output_dir, "raw.csv"), row.names = FALSE)
write.csv(summary, file.path(output_dir, "summary.csv"), row.names = FALSE)
write.csv(do.call(rbind, profile), file.path(output_dir, "profile.csv"), row.names = FALSE)
print(summary, row.names = FALSE)
cat("Saved raw.csv, summary.csv, profile.csv in:", output_dir, "\n")
