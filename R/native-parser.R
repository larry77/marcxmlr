# Native parser controls are internal regression/benchmark switches, not public
# engine APIs. The R/xml2 parser remains the semantic/error-reporting fallback.

.native_marcxml_plan <- function(
  file,
  mode = c("read", "stream"),
  n_max = Inf
) {
  mode <- match.arg(mode)

  if (!isTRUE(getOption("marcxmlr.native", TRUE))) {
    return(list(
      status = "unavailable",
      reason = "native_disabled",
      plan = NULL
    ))
  }

  valid_file <- is.character(file) &&
    length(file) == 1L &&
    !is.na(file)

  if (!valid_file) {
    stop("`file` must be one non-missing path.", call. = FALSE)
  }

  if (!file.exists(file)) {
    stop(
      sprintf("MARCXML file does not exist: %s", file),
      call. = FALSE
    )
  }

  if (identical(mode, "read")) {
    n_max <- .validate_n_max(n_max)
  } else {
    n_max <- Inf
  }

  normalized <- normalizePath(
    file,
    winslash = "/",
    mustWork = TRUE
  )

  .Call(
    C_marcxml_plan_open,
    normalized,
    if (identical(mode, "read")) 0L else 1L,
    as.double(n_max)
  )
}

.native_marcxml_plan_info <- function(plan) {
  if (!is.list(plan) ||
      !identical(plan$status, "supported") ||
      is.null(plan$plan)) {
    stop(
      "`plan` must be a supported native MARCXML plan.",
      call. = FALSE
    )
  }

  .Call(C_marcxml_plan_info, plan$plan)
}

.native_marcxml_plan_close <- function(plan) {
  if (!is.list(plan) ||
      !identical(plan$status, "supported") ||
      is.null(plan$plan)) {
    return(invisible(FALSE))
  }

  invisible(.Call(C_marcxml_plan_close, plan$plan))
}

# Development/regression helper: materialize one planned record directly from
# an xmlTextReader-expanded node. Public readers use the sequential batch API
# below rather than rescanning for individual records.
.native_marcxml_plan_record <- function(
  plan,
  record_index,
  record_id = record_index
) {
  if (!is.list(plan) ||
      !identical(plan$status, "supported") ||
      is.null(plan$plan)) {
    stop(
      "`plan` must be a supported native MARCXML plan.",
      call. = FALSE
    )
  }

  valid_index <- length(record_index) == 1L &&
    is.numeric(record_index) &&
    !is.na(record_index) &&
    is.finite(record_index) &&
    record_index >= 1 &&
    record_index == floor(record_index)

  if (!valid_index) {
    stop(
      "`record_index` must be one positive whole number.",
      call. = FALSE
    )
  }

  record_id <- .validate_record_id(record_id)

  columns <- .Call(
    C_marcxml_plan_write_record,
    plan$plan,
    as.double(record_index),
    record_id
  )

  tibble::new_tibble(
    columns,
    nrow = length(columns[[1L]])
  )
}

.native_marcxml_direct_reader_open <- function(plan) {
  if (!is.list(plan) ||
      !identical(plan$status, "supported") ||
      is.null(plan$plan)) {
    stop(
      "`plan` must be a supported native MARCXML plan.",
      call. = FALSE
    )
  }

  .Call(C_marcxml_direct_reader_open, plan$plan)
}

.native_marcxml_direct_reader_next <- function(
  reader,
  batch_records = 5000L
) {
  batch_records <- .validate_positive_whole_number(
    batch_records,
    "batch_records"
  )

  raw <- .Call(
    C_marcxml_direct_reader_next,
    reader,
    as.integer(batch_records)
  )

  if (is.null(raw)) {
    return(NULL)
  }

  data <- tibble::new_tibble(
    raw$columns,
    nrow = length(raw$columns[[1L]])
  )

  list(
    data = data,
    records = as.integer(raw$records),
    first_record_id = as.integer(raw$first_record_id)
  )
}

.native_marcxml_direct_reader_close <- function(reader) {
  invisible(.Call(C_marcxml_direct_reader_close, reader))
}

.native_marcxml_direct_collect <- function(
  plan,
  batch_records = 5000L
) {
  reader <- .native_marcxml_direct_reader_open(plan)

  on.exit(
    .native_marcxml_direct_reader_close(reader),
    add = TRUE
  )

  parts <- list()

  repeat {
    batch <- .native_marcxml_direct_reader_next(
      reader,
      batch_records = batch_records
    )

    if (is.null(batch)) {
      break
    }

    parts[[length(parts) + 1L]] <- batch$data
  }

  if (length(parts) == 0L) {
    return(.empty_marcxml())
  }

  .bind_marcxml_results(parts)
}

.native_marcxml_direct_read <- function(
  file,
  n_max = Inf
) {
  if (!isTRUE(getOption("marcxmlr.native", TRUE)) ||
      !isTRUE(getOption("marcxmlr.direct", TRUE))) {
    return(NULL)
  }

  plan <- .native_marcxml_plan(
    file = file,
    mode = "read",
    n_max = n_max
  )

  if (!identical(plan$status, "supported")) {
    return(NULL)
  }

  on.exit(
    .native_marcxml_plan_close(plan),
    add = TRUE
  )

  info <- .native_marcxml_plan_info(plan)
  record_count <- info$records_selected

  if (record_count == 0) {
    return(.empty_marcxml())
  }

  reader <- .native_marcxml_direct_reader_open(plan)

  on.exit(
    .native_marcxml_direct_reader_close(reader),
    add = TRUE
  )

  # read_marcxml() already commits to holding the complete result. For ordinary
  # catalogues allocate/fill it once rather than binding intermediate batches.
  if (record_count <= .Machine$integer.max) {
    batch <- .native_marcxml_direct_reader_next(
      reader,
      batch_records = as.integer(record_count)
    )

    if (is.null(batch)) {
      stop(
        "Native MARCXML direct reader ended before its planned records.",
        call. = FALSE
      )
    }

    extra <- .native_marcxml_direct_reader_next(
      reader,
      batch_records = 1L
    )

    if (!is.null(extra)) {
      stop(
        "Native MARCXML direct reader produced more records than planned.",
        call. = FALSE
      )
    }

    return(batch$data)
  }

  # Defensive long-record-count fallback. The complete result remains an
  # in-memory object, but no single native call needs an integer-sized record
  # count larger than R can express.
  parts <- list()

  repeat {
    batch <- .native_marcxml_direct_reader_next(
      reader,
      batch_records = 5000L
    )

    if (is.null(batch)) {
      break
    }

    parts[[length(parts) + 1L]] <- batch$data
  }

  if (length(parts) == 0L) {
    return(.empty_marcxml())
  }

  .bind_marcxml_results(parts)
}

# Retained owned-string native parser. Keep each native batch small even when a
# public task spans a catalogue; in particular, never coerce an entire mori
# shared vector to ordinary memory. NULL requests the R reference parser.
.native_marcxml_records <- function(records, indices, record_ids = indices) {
  if (!isTRUE(getOption("marcxmlr.native", TRUE))) {
    return(NULL)
  }

  count <- length(indices)
  if (count == 0L) {
    return(.empty_marcxml())
  }
  if (anyNA(record_ids) || any(record_ids < 1 |
      record_ids > .Machine$integer.max | record_ids != floor(record_ids))) {
    return(NULL)
  }

  starts <- seq.int(1L, count, by = 256L)
  parts <- vector("list", length(starts))
  for (i in seq_along(starts)) {
    positions <- seq.int(starts[[i]], min(count, starts[[i]] + 255L))
    texts <- purrr::map_chr(indices[positions], function(index) records[[index]])
    columns <- .Call(
      C_marcxml_parse_records,
      texts,
      as.integer(record_ids[positions])
    )
    if (is.null(columns)) {
      # Re-run the original task, preserving its validation order, messages,
      # and indexed purrr conditions, including failures after earlier records.
      return(NULL)
    }
    parts[[i]] <- tibble::new_tibble(columns, nrow = length(columns[[1L]]))
  }

  if (length(parts) == 1L) parts[[1L]] else .bind_marcxml_results(parts)
}

# Retained bounded-memory serializer. Returning NULL means the unchanged
# XML-package event-stream implementation must be used.
.native_marcxml_reader_open <- function(file) {
  if (!isTRUE(getOption("marcxmlr.native", TRUE)) ||
      !isTRUE(getOption("marcxmlr.native_stream", TRUE))) {
    return(NULL)
  }

  .Call(C_marcxml_reader_open, file)
}

.native_marcxml_reader_next <- function(reader, batch_records) {
  .Call(
    C_marcxml_reader_next,
    reader,
    as.integer(batch_records)
  )
}

.native_marcxml_reader_close <- function(reader) {
  invisible(.Call(C_marcxml_reader_close, reader))
}

.native_marcxml_stream <- function(
  file,
  batch_records,
  consume
) {
  reader <- .native_marcxml_reader_open(file)

  if (is.null(reader)) {
    return(FALSE)
  }

  on.exit(
    .native_marcxml_reader_close(reader),
    add = TRUE
  )

  repeat {
    records <- .native_marcxml_reader_next(
      reader,
      batch_records
    )

    if (length(records) == 0L) {
      break
    }

    consume(records)
  }

  TRUE
}
