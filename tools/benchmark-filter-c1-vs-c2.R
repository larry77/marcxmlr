#!/usr/bin/env Rscript
# Experimental C1 versus buffered C2 comparison (single machine).
# Benchmark runs only after exact equality; no new API or CRAN release.
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1L || !file.exists(args[[1L]])) {
  stop("Usage: Rscript tools/benchmark-filter-c1-vs-c2.R FILE.xml [repetitions]",
       call. = FALSE)
}
file <- normalizePath(args[[1L]], mustWork = TRUE)
reps <- if (length(args) >= 2L) as.integer(args[[2L]]) else 3L
if (is.na(reps) || reps < 1L) stop("repetitions must be positive", call. = FALSE)
library(marcxmlr)

filters <- list(
  rare_856 = "856",
  intermediate_710 = "710",
  common_650 = "650"
)
keep_tag <- function(x, ids) ids %in% unique(x$record_id)
fun <- list(
  c1 = marcxmlr:::.prototype_read_marcxml_filtered,
  c2 = marcxmlr:::.prototype_read_marcxml_buffered
)
results <- list()
for (case in names(filters)) {
  tag <- filters[[case]]
  cat("Checking", case, "...\n")
  a <- fun$c1(file, tag, keep_tag, screen_batch_records = 1000L)
  b <- fun$c2(file, tag, keep_tag, screen_batch_records = 1000L)
  stopifnot(identical(a, b))
  rm(a, b)
  gc()
  for (name in names(fun)) {
    for (i in seq_len(reps + 1L)) {
      gc()
      time <- system.time({
        res <- fun[[name]](file, tag, keep_tag, screen_batch_records = 1000L)
        nr <- nrow(res)
      })[["elapsed"]]
      if (i > 1L) {
        results[[length(results) + 1L]] <- data.frame(
          case = case, method = name, run = i - 1L,
          elapsed_s = time, canonical_rows = nr
        )
      }
      rm(res)
      cat(case, name, i, sprintf("%.3f s", time), "\n")
    }
  }
}
out <- do.call(rbind, results)
path <- file.path(path.expand("~"),
                  paste0("marcxmlr-buffered-c2-", format(Sys.time(), "%Y%m%d-%H%M%S")))
dir.create(path)
write.csv(out, file.path(path, "raw.csv"), row.names = FALSE)
med <- aggregate(elapsed_s ~ case + method, out, median)
write.csv(med, file.path(path, "summary.csv"), row.names = FALSE)
print(med, row.names = FALSE)
cat("Saved to", path, "\n")
