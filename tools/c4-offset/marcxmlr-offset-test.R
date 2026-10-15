# Standalone R front end for C4 byte-offset feasibility experiment.
# Requires: installed marcxmlr, cc, libexpat development headers and library.
# It does NOT modify the marcxmlr package. Intended for ordinary UTF-8
# uncompressed MARCXML collections using the default MARC21 namespace.
#
# Usage:
#   source("marcxmlr-offset-test.R")
#   x <- offset_test("/path/to/gpo-sample.xml", tag = "856", verify = TRUE)
#   x$index
#   x$timings
#   x$identical_to_full
#
# Optional:
#   x <- offset_test("/path/to/catalogue.xml", tag = "650",
#                    subfield = "a", equals = "Flood insurance",
#                    max_records = Inf)

.offset_demo_dir <- local({
  src <- tryCatch(sys.frame(1L)$ofile, error = function(e) NULL)
  if (is.null(src)) getwd() else dirname(normalizePath(src))
})

.compile_indexer <- function(helper_c, force = FALSE) {
  if (!file.exists(helper_c)) {
    stop("Cannot find C helper: ", helper_c, call. = FALSE)
  }
  output <- file.path(tempdir(), "record_offset_index")
  if (file.exists(output) && !force) return(output)
  compiler <- Sys.which("cc")
  if (!nzchar(compiler)) stop("C compiler 'cc' is required", call. = FALSE)

  errors <- tempfile("offset-compile-")
  on.exit(unlink(errors), add = TRUE)
  status <- suppressWarnings(system2(
    compiler,
    args = c("-O2", "-std=c99", "-Wall", "-Wextra",
             shQuote(normalizePath(helper_c)), "-o", shQuote(output), "-lexpat"),
    stdout = errors, stderr = errors
  ))
  if (!identical(as.integer(status), 0L)) {
    stop("Indexer compilation failed. Install libexpat1-dev on Debian.\n",
         paste(readLines(errors, warn = FALSE), collapse = "\n"), call. = FALSE)
  }
  output
}

# This checks the source encoding because the offset experiment is UTF-8 only.
.check_utf8 <- function(file) {
  con <- base::file(file, "rb")
  on.exit(close(con), add = TRUE)
  head <- readBin(con, "raw", n = 512L)
  if (length(head) >= 2L &&
      (identical(as.integer(head[1:2]), c(255L, 254L)) ||
       identical(as.integer(head[1:2]), c(254L, 255L)))) {
    stop("UTF-16 source unsupported by this experiment.", call. = FALSE)
  }
  if (any(head == as.raw(0))) stop("Non-UTF-8 source unsupported.", call. = FALSE)
  prefix <- rawToChar(head)
  decl <- regmatches(prefix, regexec("^<\\?xml[^>]*\\bencoding\\s*=\\s*['\"]([^'\"]+)",
                                       prefix, perl = TRUE))[[1L]]
  if (length(decl) > 1L && !identical(toupper(decl[[2L]]), "UTF-8")) {
    stop("Only UTF-8 XML is supported by this prototype.", call. = FALSE)
  }
}

# Write the *original bytes* of matching records, accessed by seek(), into
# a temporary MARCXML collection. Never seek through unselected records.
.extract_selected <- function(file, offsets, output) {
  src <- base::file(file, open = "rb")
  dst <- base::file(output, open = "wb")
  on.exit({ close(dst); close(src) }, add = TRUE)
  writeBin(charToRaw('<collection xmlns="http://www.loc.gov/MARC21/slim" xmlns:marc="http://www.loc.gov/MARC21/slim">\n'), dst)
  for (i in seq_len(nrow(offsets))) {
    start <- offsets$start_byte[[i]]
    n <- offsets$end_byte[[i]] - start
    if (!is.finite(n) || n < 1 || n > 64 * 1024^2 || n != floor(n)) {
      stop("Unreasonable record byte span at selected row ", i, call. = FALSE)
    }
    seek(src, where = start, origin = "start")
    bytes <- readBin(src, what = "raw", n = as.integer(n))
    if (length(bytes) != n) stop("Cannot read selected fragment ", i, call. = FALSE)
    writeBin(bytes, dst)
    writeBin(as.raw(10), dst)
  }
  writeBin(charToRaw("</collection>\n"), dst)
  invisible(output)
}

offset_test <- function(file, tag = "856", subfield = NULL, equals = NULL,
                        max_records = Inf, verify = FALSE,
                        helper_c = file.path(.offset_demo_dir, "record_offset_index.c")) {
  stopifnot(requireNamespace("marcxmlr", quietly = TRUE))
  file <- normalizePath(file, mustWork = TRUE)
  if (!grepl("^[0-9]{3}$", tag)) stop("tag must contain three digits")
  if (!is.null(subfield) && (!is.character(subfield) || length(subfield) != 1L ||
                             nchar(subfield, type = "bytes") != 1L))
    stop("subfield must be a one-character MARC code")
  if (!is.null(equals) && is.null(subfield)) stop("equals requires subfield")
  if (length(max_records) != 1L || is.na(max_records) || max_records < 0)
    stop("max_records must be nonnegative (Inf is allowed)")
  .check_utf8(file)
  indexer <- .compile_indexer(helper_c)

  index_file <- tempfile("offset-index-", fileext = ".tsv")
  log_file <- tempfile("offset-index-", fileext = ".log")
  extracted_file <- tempfile("selected-marcxml-", fileext = ".xml")
  on.exit(unlink(c(index_file, log_file, extracted_file)), add = TRUE)

  t0 <- proc.time()[["elapsed"]]
  status <- suppressWarnings(system2(
    indexer,
    args = shQuote(c(file, tag, if (is.null(subfield)) "-" else subfield,
                     if (is.null(equals)) "-" else equals)),
    stdout = index_file, stderr = log_file
  ))
  if (!identical(as.integer(status), 0L)) {
    stop("Indexing failed:\n", paste(readLines(log_file, warn = FALSE),
                                     collapse = "\n"), call. = FALSE)
  }
  indexed <- proc.time()[["elapsed"]]
  hits <- read.delim(index_file, colClasses = c("integer", "numeric", "numeric"))
  names(hits) <- c("source_position", "start_byte", "end_byte")
  total_hits <- nrow(hits)
  if (is.finite(max_records)) hits <- head(hits, as.integer(max_records))

  result <- NULL
  if (nrow(hits) > 0L) {
    .extract_selected(file, hits, extracted_file)
    result <- marcxmlr::read_marcxml(extracted_file)
  }
  extracted <- proc.time()[["elapsed"]]

  identical_to_full <- NA
  if (verify) {
    full <- marcxmlr::read_marcxml(file) # for small test samples ONLY
    hit_rows <- full$tag == tag & full$field_type %in% c("datafield", "controlfield")
    if (!is.null(subfield)) hit_rows <- hit_rows & !is.na(full$subfield_code) &
      full$subfield_code == subfield
    if (!is.null(equals)) hit_rows <- hit_rows & !is.na(full$value) &
      full$value == equals
    ids <- unique(full$record_id[which(hit_rows)])
    if (is.finite(max_records)) ids <- head(ids, as.integer(max_records))
    expected <- full[full$record_id %in% ids, , drop = FALSE]
    if (nrow(expected)) expected$record_id <- match(expected$record_id, ids)
    rownames(expected) <- NULL
    if (is.null(result)) {
      identical_to_full <- (nrow(expected) == 0L)
    } else {
      rownames(result) <- NULL
      identical_to_full <- identical(result, expected)
    }
  }
  list(
    matched_total = total_hits,
    materialized = nrow(hits),
    index = hits,
    canonical = result,
    timings = c(screening_seconds = indexed - t0,
                direct_seek_and_marcxmlr_seconds = extracted - indexed),
    identical_to_full = identical_to_full
  )
}

# Command-line execution (optional):
# Rscript marcxmlr-offset-test.R /path/to/file.xml 856
# Use max_records = 10 for the CLI preview; use source() for complete control.
if (sys.nframe() == 0L) {
  args <- commandArgs(trailingOnly = TRUE)
  if (length(args) < 1L) stop("Usage: Rscript marcxmlr-offset-test.R FILE [TAG]")
  res <- offset_test(args[[1L]], tag = if (length(args) >= 2L) args[[2L]] else "856",
                     max_records = 10L)
  print(head(res$index, 10L))
  cat("Total matching records:", res$matched_total, "\n")
  cat("Materialized:", res$materialized, "\n")
  print(res$timings)
  if (!is.null(res$canonical))
    cat("Canonical rows:", nrow(res$canonical), "\n")
}
