# Experimental complete-record screening prototype.
# Intentionally not exported and not wired into the public readers yet.
# The normal unfiltered native execution paths are completely untouched.

.prototype_filter_plan <- function(file, filter_tags, record_filter,
                                   n_max = Inf, screen_batch_records = 1000L,
                                   .profile = FALSE, .fused = FALSE) {
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

  # The default remains the tested C1 path. Fusion is opt-in for measurement.
  screening <- .Call(
    if (isTRUE(.fused)) C_marcxml_filter_screen_open_fused
    else C_marcxml_filter_screen_open,
    normalizePath(file, winslash = "/", mustWork = TRUE),
    tags,
    as.double(n_max),
    isTRUE(.profile)
  )
  on.exit(.Call(C_marcxml_filter_screen_close, screening), add = TRUE)
  callback_s <- 0
  callback_batches <- 0L

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
    callback_start <- if (.profile) proc.time()[["elapsed"]] else 0
    keep <- record_filter(data, ids)
    if (.profile) {
      callback_s <- callback_s + proc.time()[["elapsed"]] - callback_start
      callback_batches <- callback_batches + 1L
    }
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
  native_profile <- if (.profile) {
    .Call(C_marcxml_filter_screen_profile, screening)
  } else NULL
  result <- .Call(C_marcxml_filter_screen_finish, screening)
  if (.profile) {
    attr(result, "experimental_filter_profile") <- c(
      native_profile,
      r_filter_callback_s = callback_s,
      r_filter_callback_batches = callback_batches
    )
  }
  result
}

.prototype_read_marcxml_filtered <- function(file, filter_tags, record_filter,
                                            n_max = Inf,
                                            screen_batch_records = 1000L,
                                            .fused = FALSE) {
  plan <- .prototype_filter_plan(
    file, filter_tags, record_filter, n_max, screen_batch_records,
    .fused = .fused
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

# Linux-only, experimental timings. No changes to public entrypoints.
# This function intentionally constructs the same complete in-memory result as
# .prototype_read_marcxml_filtered(), so the profile includes final R binding.
.prototype_profile_marcxml_filtered <- function(
    file, filter_tags, record_filter, n_max = Inf,
    screen_batch_records = 1000L, batch_records = 5000L,
    .fused = FALSE) {
  if (.Platform$OS.type != "unix" || !file.exists("/proc/self/status")) {
    stop("The experimental native profiling clock requires Linux.", call. = FALSE)
  }
  batch_records <- .validate_positive_whole_number(batch_records, "batch_records")
  elapsed <- function() proc.time()[["elapsed"]]
  total_start <- elapsed()

  plan_start <- elapsed()
  plan <- .prototype_filter_plan(
    file, filter_tags, record_filter, n_max, screen_batch_records,
    .profile = TRUE, .fused = .fused
  )
  plan_s <- elapsed() - plan_start
  on.exit(.native_marcxml_recovery_plan_close(plan), add = TRUE)
  screen_profile <- attr(plan, "experimental_filter_profile")
  info <- .native_marcxml_recovery_plan_info(plan)

  second_open_s <- 0
  second_calls_s <- 0
  second_profile <- c(native_second_next_s = 0,
                      native_second_validate_s = 0,
                      native_second_write_s = 0)
  bind_s <- 0
  if (info$records_valid == 0) {
    result <- .empty_marcxml()
  } else {
    t <- elapsed()
    reader <- .native_marcxml_recovery_reader_open(plan)
    second_open_s <- elapsed() - t
    on.exit(.native_marcxml_recovery_reader_close(reader), add = TRUE)
    parts <- list()
    repeat {
      t <- elapsed()
      batch <- .native_marcxml_recovery_reader_next(reader, batch_records)
      second_calls_s <- second_calls_s + elapsed() - t
      if (is.null(batch)) break
      parts[[length(parts) + 1L]] <- batch$data
    }
    second_profile <- .Call(C_marcxml_recovery_filter_profile, reader)
    t <- elapsed()
    result <- .bind_marcxml_results(parts)
    bind_s <- elapsed() - t
  }

  total_s <- elapsed() - total_start
  v <- c(
    total_s = total_s,
    plan_and_screen_s = plan_s,
    screen_native_s = unname(screen_profile[["native_screen_next_s"]]),
    screen_validate_s = unname(screen_profile[["native_expand_count_s"]]),
    screen_extract_s = unname(screen_profile[["native_selected_extract_s"]]),
    screen_pack_s = unname(screen_profile[["native_screen_pack_s"]]),
    r_filter_callback_s = unname(screen_profile[["r_filter_callback_s"]]),
    second_open_s = second_open_s,
    second_r_calls_s = second_calls_s,
    second_native_s = unname(second_profile[["native_second_next_s"]]),
    second_revalidate_s = unname(second_profile[["native_second_validate_s"]]),
    second_write_s = unname(second_profile[["native_second_write_s"]]),
    bind_s = bind_s
  )
  # The residuals are important: scan overhead is not identified separately
  # from XML traversal, bookkeeping, and allocations. Categories must not be
  # double counted (native subtimings are *inside* screen/second totals).
  v <- c(v,
    screen_native_other_s = max(0, v[["screen_native_s"]] -
      v[["screen_validate_s"]] - v[["screen_extract_s"]] - v[["screen_pack_s"]]),
    second_native_other_s = max(0, v[["second_native_s"]] -
      v[["second_revalidate_s"]] - v[["second_write_s"]]),
    plan_r_other_s = max(0, plan_s - v[["screen_native_s"]] -
      v[["r_filter_callback_s"]]),
    second_r_other_s = max(0, second_calls_s - v[["second_native_s"]]),
    total_other_s = max(0, total_s - plan_s - second_open_s -
      second_calls_s - bind_s)
  )
  list(
    result = result,
    timings = v,
    counts = c(
      source_records_scanned = screen_profile[["source_records_scanned"]],
      selected_records = info$records_valid,
      screening_rows = screen_profile[["screening_rows"]],
      selected_canonical_rows = nrow(result),
      screen_batches = screen_profile[["screen_batches"]]
    )
  )
}
