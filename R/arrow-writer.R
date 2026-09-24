.writer_is_arrow_source <- function(x) {
  inherits(x, "Dataset") || inherits(x, "arrow_dplyr_query")
}

.writer_arrow_batch_size <- function() {
  value <- getOption("marcxmlr.writer_arrow_batch_size", 65536L)
  valid <- length(value) == 1L && is.numeric(value) && !is.na(value) &&
    is.finite(value) && value > 0 && value == floor(value) &&
    value <= .Machine$integer.max

  if (!valid) {
    rlang::abort(
      "Internal Arrow writer batch size is invalid.",
      class = "marcxmlr_internal_error"
    )
  }

  as.integer(value)
}

.writer_arrow_reader <- function(x) {
  if (!requireNamespace("arrow", quietly = TRUE)) {
    rlang::abort(
      "Writing a lazy Arrow source requires the optional `arrow` package.",
      class = "marcxmlr_missing_dependency"
    )
  }

  arrow::Scanner$create(
    x,
    projection = .writer_canonical_columns,
    use_threads = FALSE,
    batch_size = .writer_arrow_batch_size()
  )$ToRecordBatchReader()
}

.writer_arrow_missing_columns <- function(x) {
  setdiff(.writer_canonical_columns, names(x))
}

.writer_arrow_abort_missing_columns <- function(missing_columns) {
  diagnostics <- .writer_diagnostic_issue(
    "error",
    "missing_columns",
    paste0(
      "Missing required canonical column(s): ",
      paste(missing_columns, collapse = ", "),
      "."
    )
  )

  rlang::abort(
    .writer_format_condition(
      diagnostics,
      "Canonical representation is not structurally safe to serialize:"
    ),
    class = "marcxmlr_canonical_error",
    diagnostics = diagnostics
  )
}

.writer_arrow_record_ids <- function(x) {
  if (!.writer_is_integerish(x$record_id, allow_na = FALSE) ||
      any(x$record_id <= 0)) {
    diagnostics <- .writer_diagnostic_issue(
      "error",
      "invalid_record_id",
      "`record_id` must be non-missing and positive for every row."
    )

    rlang::abort(
      .writer_format_condition(
        diagnostics,
        "Canonical representation is not structurally safe to serialize:"
      ),
      class = "marcxmlr_canonical_error",
      diagnostics = diagnostics
    )
  }

  as.integer(x$record_id)
}

.writer_arrow_check_stream_order <- function(record_id, previous_id = NULL) {
  if (length(record_id) == 0L) {
    return(previous_id)
  }

  if (!is.null(previous_id) && record_id[[1L]] < previous_id) {
    rlang::abort(
      paste0(
        "Lazy Arrow input is not grouped in non-decreasing `record_id` order. ",
        "Bounded MARCXML writing requires all rows for a record to be contiguous."
      ),
      class = "marcxmlr_arrow_order_error"
    )
  }

  if (length(record_id) > 1L &&
      any(record_id[-1L] < record_id[-length(record_id)])) {
    rlang::abort(
      paste0(
        "Lazy Arrow input is not grouped in non-decreasing `record_id` order. ",
        "Bounded MARCXML writing requires all rows for a record to be contiguous."
      ),
      class = "marcxmlr_arrow_order_error"
    )
  }

  record_id[[length(record_id)]]
}

.writer_arrow_add_warnings <- function(current, diagnostics, limit = 1000L) {
  warnings <- diagnostics[diagnostics$severity == "warning", , drop = FALSE]
  warnings <- warnings[warnings$code != "record_id_will_renumber", , drop = FALSE]

  if (nrow(warnings) == 0L || nrow(current) >= limit) {
    return(current)
  }

  remaining <- limit - nrow(current)
  warnings <- warnings[seq_len(min(nrow(warnings), remaining)), , drop = FALSE]
  rbind(current, warnings)
}

.writer_native_stream_open <- function(file, pretty) {
  .Call(C_marcxml_stream_writer_open, file, pretty)
}

.writer_native_stream_append <- function(handle, x, record_ids) {
  columns <- .writer_native_columns(x, record_ids)
  .Call(C_marcxml_stream_writer_append, handle, columns)
  invisible(handle)
}

.writer_native_stream_close <- function(handle) {
  invisible(.Call(C_marcxml_stream_writer_close, handle))
}

.writer_stream_shard_path <- function(file, index) {
  filename <- basename(file)
  extension_start <- regexpr("\\.[^.]*$", filename)[[1L]]

  if (extension_start <= 1L) {
    stem <- filename
    extension <- ""
  } else {
    stem <- substr(filename, 1L, extension_start - 1L)
    extension <- substr(filename, extension_start, nchar(filename))
  }

  file.path(dirname(file), sprintf("%s-%05d%s", stem, index, extension))
}

.writer_commit_staged_paths <- function(staged, paths) {
  missing_staged <- staged[!file.exists(staged)]
  if (length(missing_staged) > 0L) {
    rlang::abort(
      "One or more staged MARCXML output files were not created.",
      class = "marcxmlr_output_error"
    )
  }

  existing <- paths[file.exists(paths)]
  if (length(existing) > 0L) {
    rlang::abort(
      paste0(
        "Output file(s) appeared while writing; no staged files were committed: ",
        paste(existing, collapse = ", ")
      ),
      class = "marcxmlr_output_exists",
      paths = existing
    )
  }

  committed <- character()
  success <- FALSE
  on.exit({
    if (!success && length(committed) > 0L) {
      unlink(committed[file.exists(committed)], force = TRUE)
    }
  }, add = TRUE)

  for (i in seq_along(paths)) {
    if (!isTRUE(suppressWarnings(file.rename(staged[[i]], paths[[i]])))) {
      rlang::abort(
        sprintf("Could not commit staged MARCXML output: %s", paths[[i]]),
        class = "marcxmlr_output_error",
        path = paths[[i]]
      )
    }
    committed <- c(committed, paths[[i]])
  }

  success <- TRUE
  invisible(paths)
}

.writer_write_arrow <- function(
  x,
  file,
  check,
  pretty,
  records_per_file
) {
  missing_columns <- .writer_arrow_missing_columns(x)
  if (length(missing_columns) > 0L) {
    .writer_arrow_abort_missing_columns(missing_columns)
  }

  reader <- .writer_arrow_reader(x)
  on.exit(try(reader$Close(), silent = TRUE), add = TRUE)

  carry <- NULL
  previous_stream_id <- NULL
  records_seen <- 0L
  record_id_will_renumber <- FALSE
  warning_diagnostics <- .writer_empty_diagnostics()

  staged <- character()
  paths <- character()
  handle <- NULL
  records_in_shard <- 0L
  shard_index <- 0L
  success <- FALSE

  close_handle <- function() {
    if (!is.null(handle)) {
      .writer_native_stream_close(handle)
      handle <<- NULL
    }
    invisible(NULL)
  }

  start_shard <- function() {
    shard_index <<- shard_index + 1L
    target <- if (is.infinite(records_per_file)) {
      file
    } else {
      .writer_stream_shard_path(file, shard_index)
    }

    if (file.exists(target)) {
      rlang::abort(
        paste0("Output file already exists; no files were written: ", target),
        class = "marcxmlr_output_exists",
        paths = target
      )
    }

    stage <- .writer_temp_output_paths(target)
    paths <<- c(paths, target)
    staged <<- c(staged, stage)
    handle <<- .writer_native_stream_open(stage, pretty)
    records_in_shard <<- 0L
    invisible(NULL)
  }

  on.exit({
    if (!is.null(handle)) {
      try(.writer_native_stream_close(handle), silent = TRUE)
      handle <- NULL
    }

    if (!success && length(staged) > 0L) {
      unlink(staged[file.exists(staged)], force = TRUE)
    }
  }, add = TRUE)

  diagnose_complete <- function(rows) {
    diagnostics <- .writer_diagnose_impl(
      rows,
      include_warnings = isTRUE(check)
    )
    .writer_abort_errors(diagnostics)

    if (isTRUE(check)) {
      warning_diagnostics <<- .writer_arrow_add_warnings(
        warning_diagnostics,
        diagnostics
      )
    }

    invisible(NULL)
  }

  write_complete <- function(rows) {
    if (nrow(rows) == 0L) {
      return(invisible(NULL))
    }

    diagnose_complete(rows)
    ids <- sort(unique(as.integer(rows$record_id)))

    for (rid in ids) {
      records_seen <<- records_seen + 1L
      if (rid != records_seen) {
        record_id_will_renumber <<- TRUE
      }
    }

    position <- 1L
    while (position <= length(ids)) {
      if (is.null(handle)) {
        start_shard()
      }

      capacity <- if (is.infinite(records_per_file)) {
        length(ids) - position + 1L
      } else {
        as.integer(records_per_file) - records_in_shard
      }

      take_n <- min(capacity, length(ids) - position + 1L)
      take_ids <- ids[position:(position + take_n - 1L)]
      shard_rows <- rows[as.integer(rows$record_id) %in% take_ids, , drop = FALSE]

      .writer_native_stream_append(handle, shard_rows, take_ids)
      records_in_shard <<- records_in_shard + take_n
      position <- position + take_n

      if (!is.infinite(records_per_file) &&
          records_in_shard == as.integer(records_per_file)) {
        close_handle()
      }
    }

    invisible(NULL)
  }

  repeat {
    batch <- reader$read_next_batch()
    if (is.null(batch)) {
      break
    }

    rows <- as.data.frame(batch, stringsAsFactors = FALSE)
    if (nrow(rows) == 0L) {
      next
    }

    missing_batch <- setdiff(.writer_canonical_columns, names(rows))
    if (length(missing_batch) > 0L) {
      .writer_arrow_abort_missing_columns(missing_batch)
    }

    record_id <- .writer_arrow_record_ids(rows)
    previous_stream_id <- .writer_arrow_check_stream_order(
      record_id,
      previous_stream_id
    )

    if (!is.null(carry)) {
      carry_id <- as.integer(carry$record_id[[1L]])

      if (record_id[[1L]] == carry_id) {
        different <- which(record_id != carry_id)

        if (length(different) == 0L) {
          # One unusually large record spans this entire scanner batch. In
          # that rare case the record itself is the bounded-memory unit, so
          # extend only the carry record and wait for the next batch.
          carry <- rbind(carry, rows)
          next
        }

        prefix_n <- different[[1L]] - 1L
        if (prefix_n > 0L) {
          carry <- rbind(
            carry,
            rows[seq_len(prefix_n), , drop = FALSE]
          )
          write_complete(carry)

          keep <- seq.int(prefix_n + 1L, nrow(rows))
          rows <- rows[keep, , drop = FALSE]
          record_id <- record_id[keep]
        } else {
          write_complete(carry)
        }
      } else {
        write_complete(carry)
      }

      carry <- NULL
    }

    last_id <- record_id[[length(record_id)]]
    trailing <- record_id == last_id

    complete <- rows[!trailing, , drop = FALSE]
    carry <- rows[trailing, , drop = FALSE]
    write_complete(complete)
  }

  if (!is.null(carry) && nrow(carry) > 0L) {
    write_complete(carry)
    carry <- NULL
  }

  if (is.null(handle) && length(paths) == 0L) {
    start_shard()
  }
  close_handle()

  if (isTRUE(check) && record_id_will_renumber) {
    warning_diagnostics <- rbind(
      .writer_diagnostic_issue(
        "warning",
        "record_id_will_renumber",
        paste0(
          "`record_id` values are not contiguous from 1; they will be regenerated ",
          "when the written XML is reread."
        )
      ),
      warning_diagnostics
    )
  }

  if (isTRUE(check)) {
    .writer_warn_warnings(warning_diagnostics)
  }

  .writer_commit_staged_paths(staged, paths)
  success <- TRUE
  invisible(paths)
}
