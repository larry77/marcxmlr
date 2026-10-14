# Experimental complete-record screening prototype.
# Intentionally not exported and not wired into the public readers yet.
# The normal unfiltered native execution paths are completely untouched.

.prototype_filter_plan <- function(file, filter_tags, record_filter,
                                   n_max = Inf, screen_batch_records = 1000L) {
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
    stop("`filter_tags` must contain MARC field tags or 'LDR'.", call. = FALSE)
  }
  if (!isTRUE(getOption("marcxmlr.native", TRUE))) {
    stop("The experimental filter requires the native parser.", call. = FALSE)
  }

  screening <- .Call(
    C_marcxml_filter_screen_open,
    normalizePath(file, winslash = "/", mustWork = TRUE),
    tags,
    as.double(n_max)
  )
  on.exit(.Call(C_marcxml_filter_screen_close, screening), add = TRUE)

  repeat {
    batch <- .Call(
      C_marcxml_filter_screen_next,
      screening,
      as.integer(screen_batch_records)
    )
    if (is.null(batch)) break
    data <- tibble::new_tibble(batch$columns,
                               nrow = length(batch$columns[[1L]]))
    ids <- batch$record_ids
    # The screening callback gets all source record IDs, including those
    # with no matching field. It must return exactly one decision per record.
    keep <- record_filter(data, ids)
    if (!is.logical(keep) || length(keep) != length(ids) || anyNA(keep)) {
      stop(paste0(
        "`record_filter` must return a non-missing logical vector with ",
        "one element per input record, in the supplied `record_ids` order."
      ), call. = FALSE)
    }
    .Call(C_marcxml_filter_screen_apply, screening, keep)
  }

  # Native screening first pass is complete. The returned object uses the
  # existing sparse-record native writer for the second pass.
  result <- .Call(C_marcxml_filter_screen_finish, screening)
  result
}

.prototype_read_marcxml_filtered <- function(file, filter_tags, record_filter,
                                            n_max = Inf,
                                            screen_batch_records = 1000L) {
  plan <- .prototype_filter_plan(
    file, filter_tags, record_filter, n_max, screen_batch_records
  )
  on.exit(.native_marcxml_recovery_plan_close(plan), add = TRUE)
  info <- .native_marcxml_recovery_plan_info(plan)
  if (info$records_valid == 0) return(.empty_marcxml())
  reader <- .native_marcxml_recovery_reader_open(plan)
  on.exit(.native_marcxml_recovery_reader_close(reader), add = TRUE)

  parts <- list()
  repeat {
    batch <- .native_marcxml_recovery_reader_next(reader, batch_records = 5000L)
    if (is.null(batch)) break
    parts[[length(parts) + 1L]] <- batch$data
  }
  .bind_marcxml_results(parts)
}

.prototype_marcxml_to_parquet_filtered <- function(
    file, output_dir, filter_tags, record_filter,
    screen_batch_records = 1000L, batch_records = 5000L,
    compression = "snappy") {
  if (!requireNamespace("arrow", quietly = TRUE)) {
    stop("The Arrow package is required.", call. = FALSE)
  }
  batch_records <- .validate_positive_whole_number(batch_records, "batch_records")
  if (file.exists(output_dir)) {
    stop("`output_dir` already exists.", call. = FALSE)
  }
  parent <- dirname(output_dir)
  if (!dir.exists(parent)) stop("Output parent directory does not exist.", call. = FALSE)
  stage <- tempfile("marcxmlr-filter-", tmpdir = parent)
  if (!dir.create(stage)) stop("Could not create staging directory.", call. = FALSE)
  committed <- FALSE
  on.exit(if (!committed) unlink(stage, recursive = TRUE, force = TRUE), add = TRUE)

  plan <- .prototype_filter_plan(
    file, filter_tags, record_filter, n_max = Inf, screen_batch_records
  )
  on.exit(.native_marcxml_recovery_plan_close(plan), add = TRUE)
  reader <- .native_marcxml_recovery_reader_open(plan)
  on.exit(.native_marcxml_recovery_reader_close(reader), add = TRUE)

  records <- 0L
  rows <- 0
  n_parts <- 0L
  repeat {
    batch <- .native_marcxml_recovery_reader_next(reader, batch_records)
    if (is.null(batch)) break
    n_parts <- n_parts + 1L
    arrow::write_parquet(
      batch$data,
      file.path(stage, sprintf("part-%06d.parquet", n_parts)),
      compression = compression
    )
    records <- records + batch$records
    rows <- rows + nrow(batch$data)
  }
  if (n_parts == 0L) {
    arrow::write_parquet(
      .empty_marcxml(), file.path(stage, "part-000001.parquet"),
      compression = compression
    )
    n_parts <- 1L
  }
  if (!file.rename(stage, output_dir)) {
    stop("Could not publish filtered Parquet dataset.", call. = FALSE)
  }
  committed <- TRUE
  invisible(tibble::tibble(
    input_file = file,
    output_dir = normalizePath(output_dir, winslash = "/"),
    records = records,
    rows = rows,
    parquet_files = n_parts
  ))
}
