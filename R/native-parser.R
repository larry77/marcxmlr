# Internal switch for regression tests and benchmarks, not a public engine API.
# Keep each owned native batch small even when a public task spans a catalogue.
# In particular, never coerce an entire mori shared vector to ordinary memory.
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


# Stateful bounded-memory reader for ordinary MARCXML collections. Returning
# NULL means the unchanged XML-package streaming implementation must be used.
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
