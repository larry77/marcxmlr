# Experimental single-pass (C2) complete-record filtering. Not exported.
# C1 and the package's public unfiltered paths remain unchanged.
# Caller-supplied filters see the same nine-column screening table as C1.

.prototype_read_marcxml_buffered <- function(
    file, filter_tags, record_filter, n_max = Inf,
    screen_batch_records = 1000L) {
  if (!is.character(file) || length(file) != 1L || is.na(file) ||
      !file.exists(file)) {
    stop("`file` must be an existing MARCXML file.", call. = FALSE)
  }
  if (!is.character(filter_tags) || !length(filter_tags) ||
      anyNA(filter_tags) || any(!nzchar(filter_tags))) {
    stop("`filter_tags` must be a non-empty character vector of tags.",
         call. = FALSE)
  }
  if (!is.function(record_filter)) {
    stop("`record_filter` must be a function.", call. = FALSE)
  }
  screen_batch_records <- .validate_positive_whole_number(
    screen_batch_records, "screen_batch_records"
  )
  n_max <- .validate_n_max(n_max)
  tags <- unique(filter_tags)
  if (any(!grepl("^(LDR|[0-9]{3})$", tags))) {
    stop("`filter_tags` must contain MARC field tags or 'LDR'.",
         call. = FALSE)
  }
  if (!isTRUE(getOption("marcxmlr.native", TRUE))) {
    stop("The experimental filter requires the native parser.",
         call. = FALSE)
  }

  reader <- .Call(
    C_marcxml_filter_buffer_open,
    normalizePath(file, winslash = "/", mustWork = TRUE),
    tags, as.double(n_max)
  )
  on.exit(.Call(C_marcxml_filter_screen_close, reader), add = TRUE)

  parts <- list()
  repeat {
    batch <- .Call(C_marcxml_filter_screen_next, reader,
                   as.integer(screen_batch_records))
    if (is.null(batch)) break
    x <- tibble::new_tibble(batch$columns,
                            nrow = length(batch$columns[[1L]]))
    record_ids <- batch$record_ids
    keep <- record_filter(x, record_ids)
    if (!is.logical(keep) || length(keep) != length(record_ids) ||
        anyNA(keep)) {
      stop(paste0(
        "`record_filter` must return a non-missing logical vector with ",
        "one element per input record, in the supplied `record_ids` order."
      ), call. = FALSE)
    }
    columns <- .Call(C_marcxml_filter_buffer_apply, reader, keep)
    n_rows <- length(columns[[1L]])
    if (n_rows > 0L) {
      parts[[length(parts) + 1L]] <- tibble::new_tibble(columns, nrow = n_rows)
    }
  }
  .bind_marcxml_results(parts)
}

# Bounded Parquet variant using the same single-pass reader. The staging
# discipline matches the existing experimental two-pass Parquet wrapper.
.prototype_marcxml_to_parquet_buffered <- function(
    file, output_dir, filter_tags, record_filter,
    screen_batch_records = 1000L, compression = "snappy") {
  if (!requireNamespace("arrow", quietly = TRUE)) {
    stop("The Arrow package is required.", call. = FALSE)
  }
  if (!is.character(output_dir) || length(output_dir) != 1L ||
      is.na(output_dir) || !nzchar(output_dir)) {
    stop("`output_dir` must be one nonempty path.", call. = FALSE)
  }
  if (file.exists(output_dir)) {
    stop("`output_dir` already exists.", call. = FALSE)
  }
  parent <- dirname(output_dir)
  if (!dir.exists(parent)) {
    stop("Output parent directory does not exist.", call. = FALSE)
  }
  stage <- tempfile("marcxmlr-buffer-", tmpdir = parent)
  if (!dir.create(stage)) {
    stop("Could not create staging directory.", call. = FALSE)
  }
  committed <- FALSE
  on.exit(if (!committed) unlink(stage, recursive = TRUE, force = TRUE),
          add = TRUE)

  # One-pass streaming batches. Note that this intentionally differs from
  # .prototype_read_marcxml_buffered() only in how output batches are kept.
  if (!is.character(file) || length(file) != 1L || is.na(file) ||
      !file.exists(file)) {
    stop("`file` must be an existing MARCXML file.", call. = FALSE)
  }
  if (!is.character(filter_tags) || !length(filter_tags) ||
      anyNA(filter_tags) || any(!grepl("^(LDR|[0-9]{3})$", filter_tags))) {
    stop("`filter_tags` must contain MARC field tags or 'LDR'.",
         call. = FALSE)
  }
  if (!is.function(record_filter)) {
    stop("`record_filter` must be a function.", call. = FALSE)
  }
  screen_batch_records <- .validate_positive_whole_number(
    screen_batch_records, "screen_batch_records")
  if (!isTRUE(getOption("marcxmlr.native", TRUE))) {
    stop("The experimental filter requires the native parser.", call. = FALSE)
  }
  reader <- .Call(
    C_marcxml_filter_buffer_open,
    normalizePath(file, winslash = "/", mustWork = TRUE),
    unique(filter_tags), as.double(Inf)
  )
  on.exit(.Call(C_marcxml_filter_screen_close, reader), add = TRUE)

  parts <- 0L
  records <- 0L
  rows <- 0
  repeat {
    batch <- .Call(C_marcxml_filter_screen_next, reader,
                   as.integer(screen_batch_records))
    if (is.null(batch)) break
    x <- tibble::new_tibble(batch$columns,
                            nrow = length(batch$columns[[1L]]))
    record_ids <- batch$record_ids
    keep <- record_filter(x, record_ids)
    if (!is.logical(keep) || length(keep) != length(record_ids) ||
        anyNA(keep)) {
      stop("`record_filter` must return one non-missing logical per record.",
           call. = FALSE)
    }
    columns <- .Call(C_marcxml_filter_buffer_apply, reader, keep)
    n_rows <- length(columns[[1L]])
    if (n_rows == 0L) next
    parts <- parts + 1L
    arrow::write_parquet(
      tibble::new_tibble(columns, nrow = n_rows),
      file.path(stage, sprintf("part-%06d.parquet", parts)),
      compression = compression
    )
    records <- records + sum(keep)
    rows <- rows + n_rows
  }
  if (parts == 0L) {
    arrow::write_parquet(
      .empty_marcxml(), file.path(stage, "part-000001.parquet"),
      compression = compression
    )
    parts <- 1L
  }
  if (!file.rename(stage, output_dir)) {
    stop("Could not publish buffered Parquet dataset.", call. = FALSE)
  }
  committed <- TRUE
  invisible(tibble::tibble(
    input_file = file,
    output_dir = normalizePath(output_dir, winslash = "/"),
    records = records,
    rows = rows,
    parquet_files = parts
  ))
}
