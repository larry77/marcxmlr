#!/usr/bin/env Rscript
# Simultaneous C4 diagnosis and native implementation benchmark.
# Compares C1, original C4 (R copy + temp XML), and new native C4 (direct
# batched C seeks + in-memory libxml2 validation/materialization).
# Reuses the SAME Expat screen/index for the two C4 materializers.
# Usage: Rscript tools/c4-offset/profile-and-benchmark-c4-native.R FILE [REPS]
# Generates correctness.csv, raw.csv, summary.csv, environment.txt under ~.
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1L || length(args) > 2L) {
  stop("Usage: Rscript profile-and-benchmark-c4-native.R FILE [REPS]")
}
input <- normalizePath(path.expand(args[[1L]]), mustWork = TRUE)
reps <- if (length(args) == 2L) suppressWarnings(as.integer(args[[2L]])) else 3L
if (is.na(reps) || reps < 1L || reps > 30L) stop("REPS must be 1..30")
file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
script_dir <- dirname(normalizePath(sub("^--file=", "", file_arg[[1L]])))
source(file.path(script_dir, "marcxmlr-offset-test.R"), local = TRUE)
stopifnot(requireNamespace("marcxmlr", quietly = TRUE))
pkg <- asNamespace("marcxmlr")
if (!exists(".prototype_c4_native_read_offsets", pkg, inherits = FALSE)) {
  stop("Install the experimental C4-native package patch first.")
}
C1 <- get(".prototype_read_marcxml_filtered", pkg)
C4native <- get(".prototype_c4_native_read_offsets", pkg)
.check_utf8(input)
indexer <- .compile_indexer(file.path(script_dir, "record_offset_index.c"))
clock <- function() unname(proc.time()[["elapsed"]])
compact_ids <- function(x) {
  if (nrow(x)) x$record_id <- match(x$record_id, unique(x$record_id))
  rownames(x) <- NULL
  x
}
filter_c1 <- function(tag) {
  C1(input, filter_tags = tag,
     record_filter = function(screen, ids) ids %in% unique(screen$record_id)) |>
    compact_ids()
}
select_full <- function(tag) {
  whole <- marcxmlr::read_marcxml(input)
  hits <- unique(whole$record_id[whole$tag == tag &
                 whole$field_type %in% c("controlfield", "datafield")])
  compact_ids(whole[whole$record_id %in% hits, , drop = FALSE])
}
scan <- function(tag) {
  idx <- tempfile("offset-index-", fileext = ".tsv")
  log <- tempfile("offset-index-", fileext = ".log")
  on.exit(unlink(c(idx, log)), add = TRUE)
  t <- clock()
  status <- suppressWarnings(system2(
    indexer, args = shQuote(c(input, tag, "-", "-")), stdout = idx, stderr = log))
  scan_s <- clock() - t
  if (!identical(as.integer(status), 0L))
    stop("Indexer failed: ", paste(readLines(log, warn = FALSE), collapse = "\n"))
  t <- clock()
  hits <- utils::read.delim(idx, colClasses = c("integer", "numeric", "numeric"))
  names(hits) <- c("source_position", "start_byte", "end_byte")
  list(offsets = hits, scan_s = scan_s, index_load_s = clock() - t)
}

outdir <- file.path(path.expand("~"), paste0("marcxmlr-c4-native-", format(Sys.time(), "%Y%m%d-%H%M%S")))
if (!dir.create(outdir)) stop("Could not create output directory")
writeLines(c(
  paste("Input:", input),
  paste("Input bytes:", file.info(input)$size),
  paste("Time:", Sys.time()),
  paste("R:", R.version.string),
  paste("marcxmlr:", as.character(utils::packageVersion("marcxmlr"))),
  paste("OS:", paste(unlist(Sys.info()), collapse = " ")),
  "C4 R and native share a single Expat byte-range scan for each repetition.",
  "Native: batched direct fread/seek, libxml2 single document per batch.",
  "C1 timing does not include indexing. Timings use wall-clock elapsed seconds.",
  "Correctness checked outside timed repetitions; memory is not measured.",
  "Methods have randomized order within each repetition."
), file.path(outdir, "environment.txt"))

checks <- list()
raw <- list()
set.seed(20261015L)
for (tag in c("856", "710", "650")) {
  cat("\nTag", tag, "-- exact correctness checking\n")
  idx <- scan(tag)$offsets
  baseline <- filter_c1(tag)
  native <- C4native(input, idx, batch_records = 500L, batch_bytes = 16 * 1024^2)
  full <- select_full(tag)
  tmp <- tempfile("c4-r-copy-", fileext = ".xml")
  r_old <- if (nrow(idx)) {
    .extract_selected(input, idx, tmp)
    marcxmlr::read_marcxml(tmp)
  } else get(".empty_marcxml", pkg)()
  unlink(tmp)
  okay <- c(full_C1 = identical(full, baseline),
            C1_C4_R = identical(baseline, r_old),
            C1_C4_native = identical(baseline, native),
            index_C1 = length(unique(baseline$record_id)) == nrow(idx))
  checks[[tag]] <- data.frame(tag = tag, t(okay),
                               selected_records = nrow(idx),
                               canonical_rows = nrow(native))
  utils::write.csv(do.call(rbind, checks), file.path(outdir, "correctness.csv"), row.names = FALSE)
  cat("Selected:", nrow(idx), "| canonical rows:", nrow(native),
      "| correct:", all(okay), "\n")
  rm(baseline, native, full, r_old)
  gc(verbose = FALSE)
  if (!all(okay)) stop("Correctness mismatch: ", tag)

  # Warm up all methods once before repetitions.
  invisible(filter_c1(tag))
  invisible(C4native(input, idx))
  for (r in seq_len(reps)) {
    gc(verbose = FALSE)
    indexed <- scan(tag)
    hits <- indexed$offsets
    outcome <- list()
    for (method in sample(c("C1", "C4_R", "C4_native"))) {
      gc(verbose = FALSE)
      if (method == "C1") {
        t <- clock()
        tbl <- filter_c1(tag)
        diff_s <- clock() - t
        outcome[[method]] <- c(method_s = diff_s,
                               records = length(unique(tbl$record_id)),
                               rows = nrow(tbl))
      } else if (method == "C4_R") {
        xml_tmp <- tempfile("c4-r-copy-", fileext = ".xml")
        tryCatch({
          t <- clock()
          if (nrow(hits)) .extract_selected(input, hits, xml_tmp)
          copy_s <- clock() - t
          t <- clock()
          tbl <- if (nrow(hits)) marcxmlr::read_marcxml(xml_tmp) else get(".empty_marcxml", pkg)()
          parse_s <- clock() - t
          outcome[[method]] <- c(method_s = copy_s + parse_s,
                                  copy_s = copy_s, parse_s = parse_s,
                                  records = length(unique(tbl$record_id)),
                                  rows = nrow(tbl))
        }, finally = unlink(xml_tmp))
      } else {
        t <- clock()
        run <- C4native(input, hits, batch_records = 500L,
                        batch_bytes = 16 * 1024^2, .profile = TRUE)
        native_s <- clock() - t
        tbl <- run$canonical
        outcome[[method]] <- c(method_s = native_s, run$native_profile,
                                batches = run$batches,
                                records = length(unique(tbl$record_id)),
                                rows = nrow(tbl))
      }
      rm(tbl)
    }
    for (method in names(outcome)) {
      metrics <- outcome[[method]]
      raw[[length(raw) + 1L]] <- data.frame(
        tag = tag, repetition = r, method = method,
        selected_records = metrics[["records"]],
        canonical_rows = metrics[["rows"]],
        screening_s = if (method == "C1") NA_real_ else indexed$scan_s,
        index_load_s = if (method == "C1") NA_real_ else indexed$index_load_s,
        copy_s = if ("copy_s" %in% names(metrics)) metrics[["copy_s"]] else NA_real_,
        parse_s = if ("parse_s" %in% names(metrics)) metrics[["parse_s"]] else NA_real_,
        native_read_s = if ("native_read_offsets_s" %in% names(metrics)) metrics[["native_read_offsets_s"]] else NA_real_,
        native_xml_parse_s = if ("native_xml_parse_s" %in% names(metrics)) metrics[["native_xml_parse_s"]] else NA_real_,
        native_count_s = if ("native_count_s" %in% names(metrics)) metrics[["native_count_s"]] else NA_real_,
        native_write_s = if ("native_write_s" %in% names(metrics)) metrics[["native_write_s"]] else NA_real_,
        materialization_s = metrics[["method_s"]],
        total_s = metrics[["method_s"]] + if (method == "C1") 0 else indexed$scan_s + indexed$index_load_s
      )
    }
    utils::write.csv(do.call(rbind, raw), file.path(outdir, "raw.csv"), row.names = FALSE)
    cat(sprintf(" %s rep %d: C1 %.3f, old C4 %.3f, native C4 %.3f s\n", tag, r,
                outcome$C1[["method_s"]],
                outcome$C4_R[["method_s"]] + indexed$scan_s + indexed$index_load_s,
                outcome$C4_native[["method_s"]] + indexed$scan_s + indexed$index_load_s))
  }
}

dat <- do.call(rbind, raw)
keys <- unique(dat[c("tag", "method")])
summary <- do.call(rbind, lapply(seq_len(nrow(keys)), function(i) {
  sel <- dat$tag == keys$tag[[i]] & dat$method == keys$method[[i]]
  data.frame(keys[i, ],
             median_total_s = stats::median(dat$total_s[sel]),
             median_materialization_s = stats::median(dat$materialization_s[sel]),
             median_scan_s = if (keys$method[[i]] == "C1") NA_real_ else stats::median(dat$screening_s[sel]),
             median_copy_s = if (keys$method[[i]] == "C4_R") stats::median(dat$copy_s[sel]) else NA_real_,
             median_parse_s = if (keys$method[[i]] == "C4_R") stats::median(dat$parse_s[sel]) else NA_real_,
             median_native_read_s = if (keys$method[[i]] == "C4_native") stats::median(dat$native_read_s[sel]) else NA_real_,
             median_native_xml_parse_s = if (keys$method[[i]] == "C4_native") stats::median(dat$native_xml_parse_s[sel]) else NA_real_,
             selected_records = dat$selected_records[which(sel)[1L]])
}))
utils::write.csv(summary, file.path(outdir, "summary.csv"), row.names = FALSE)
cat("\nMedians:\n")
print(summary[c("tag", "method", "median_total_s", "median_materialization_s", "selected_records")], row.names = FALSE)
cat("\nSaved to:", outdir, "\n")
