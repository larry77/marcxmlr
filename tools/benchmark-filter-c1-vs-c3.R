#!/usr/bin/env Rscript
# Run from the repository root after `R CMD INSTALL .`
args <- commandArgs(trailingOnly = TRUE)
if (!length(args)) stop("Usage: Rscript tools/benchmark-filter-c1-vs-c3.R FILE [REPS]")
file <- normalizePath(args[[1]], mustWork = TRUE)
reps <- if (length(args) >= 2) as.integer(args[[2]]) else 5L
if (is.na(reps) || reps < 1L) stop("REPS must be positive")
ns <- asNamespace("marcxmlr")
c1 <- get(".prototype_read_marcxml_filtered", envir = ns)
c3 <- get(".prototype_read_marcxml_light_filtered", envir = ns)
rows <- list()
for (tag in c("856", "710", "650")) {
  predicate <- function(x, ids) ids %in% unique(x$record_id)
  a <- c1(file, tag, predicate)
  b <- c3(file, tag, predicate)
  if (nrow(a)) a$record_id <- match(a$record_id, unique(a$record_id))
  stopifnot(identical(a, b))
  cat("Verified:", tag, length(unique(b$record_id)), "records,", nrow(b), "rows\n")
  for (method in c("C1", "C3")) {
    fn <- if (method == "C1") c1 else c3
    fn(file, tag, predicate) # warm-up
    for (i in seq_len(reps)) {
      gc()
      t <- system.time(out <- fn(file, tag, predicate))[["elapsed"]]
      rows[[length(rows) + 1L]] <- data.frame(tag = tag,
        method = method, repetition = i, elapsed_s = t,
        records = length(unique(out$record_id)), canonical_rows = nrow(out))
    }
  }
}
raw <- do.call(rbind, rows)
dir <- file.path(path.expand("~"), paste0("marcxmlr-c3-", format(Sys.time(), "%Y%m%d-%H%M%S")))
dir.create(dir)
write.csv(raw, file.path(dir, "raw.csv"), row.names = FALSE)
summary <- aggregate(elapsed_s ~ tag + method, raw, median)
write.csv(summary, file.path(dir, "summary.csv"), row.names = FALSE)
print(summary)
cat("Saved benchmark:", dir, "\n")
