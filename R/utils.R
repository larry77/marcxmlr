.marcxml_namespace <- "http://www.loc.gov/MARC21/slim"

.empty_marcxml <- function() {
  tibble::tibble(
    record_id = integer(),
    field_type = character(),
    tag = character(),
    subfield_code = character(),
    value = character(),
    field_order = integer(),
    field_occurrence = integer(),
    ind1 = character(),
    ind2 = character(),
    subfield_order = integer(),
    subfield_occurrence = integer()
  )
}

.validate_record_id <- function(record_id) {
  valid <- length(record_id) == 1L &&
    is.numeric(record_id) &&
    !is.na(record_id) &&
    is.finite(record_id) &&
    record_id >= 1 &&
    record_id <= .Machine$integer.max &&
    record_id == floor(record_id)

  if (!valid) {
    stop(
      "`record_id` must be one positive whole number.",
      call. = FALSE
    )
  }

  as.integer(record_id)
}

.validate_n_max <- function(n_max) {
  valid <- length(n_max) == 1L &&
    is.numeric(n_max) &&
    !is.na(n_max) &&
    n_max >= 0 &&
    (is.infinite(n_max) || n_max == floor(n_max))

  if (!valid) {
    stop(
      "`n_max` must be a non-negative whole number or `Inf`.",
      call. = FALSE
    )
  }

  n_max
}

.validate_positive_whole_number <- function(x, argument) {
  valid <- length(x) == 1L &&
    is.numeric(x) &&
    !is.na(x) &&
    is.finite(x) &&
    x >= 1 &&
    x <= .Machine$integer.max &&
    x == floor(x)

  if (!valid) {
    stop(
      sprintf("`%s` must be one positive whole number.", argument),
      call. = FALSE
    )
  }

  as.integer(x)
}

.validate_workers <- function(workers) {
  .validate_positive_whole_number(workers, "workers")
}

.validate_chunk_records <- function(chunk_records) {
  if (is.null(chunk_records)) {
    return(NULL)
  }

  .validate_positive_whole_number(chunk_records, "chunk_records")
}

.node_namespace <- function(node) {
  xml2::xml_find_chr(node, "namespace-uri(.)")
}

.validate_marc_namespace <- function(node, description) {
  namespace <- .node_namespace(node)

  if (!namespace %in% c("", .marcxml_namespace)) {
    stop(
      sprintf(
        "%s uses namespace <%s>; expected <%s> or no namespace.",
        description,
        namespace,
        .marcxml_namespace
      ),
      call. = FALSE
    )
  }

  namespace
}

.ensure_record_namespace <- function(record_text, namespace) {
  # Serializing a child node can omit a namespace declaration inherited from
  # the collection root. Add it to make the record fragment self-contained.
  if (identical(namespace, "")) {
    return(record_text)
  }

  tag_end <- regexpr(">", record_text, fixed = TRUE)[[1L]]

  if (tag_end < 1L) {
    return(record_text)
  }

  start_tag <- substr(record_text, 1L, tag_end)
  name_match <- regexec(
    "^<[[:space:]]*([^[:space:]/>]+)",
    start_tag
  )
  matched <- regmatches(start_tag, name_match)[[1L]]

  if (length(matched) < 2L) {
    return(record_text)
  }

  qualified_name <- matched[[2L]]
  colon <- regexpr(":", qualified_name, fixed = TRUE)[[1L]]
  declaration_name <- if (colon > 0L) {
    paste0("xmlns:", substr(qualified_name, 1L, colon - 1L))
  } else {
    "xmlns"
  }

  declaration_marker <- paste0(declaration_name, "=")

  if (grepl(declaration_marker, start_tag, fixed = TRUE)) {
    return(record_text)
  }

  declaration <- sprintf(" %s=\"%s\"", declaration_name, namespace)

  paste0(
    substr(record_text, 1L, tag_end - 1L),
    declaration,
    substr(record_text, tag_end, nchar(record_text))
  )
}

.occurrence_number <- function(keys) {
  if (length(keys) == 0L) {
    return(integer())
  }

  as.integer(ave(seq_along(keys), keys, FUN = seq_along))
}

.bind_marcxml_results <- function(results) {
  if (length(results) == 0L) {
    return(.empty_marcxml())
  }

  tibble::as_tibble(purrr::list_rbind(results))
}

.make_record_chunks <- function(record_count, workers, chunk_records = NULL) {
  if (record_count == 0L) {
    return(list())
  }

  if (!is.null(chunk_records)) {
    starts <- seq.int(1L, record_count, by = chunk_records)

    return(purrr::map(starts, function(start) {
      end <- min(record_count, start + chunk_records - 1L)
      seq.int(start, end)
    }))
  }

  task_count <- if (workers == 1L) {
    1L
  } else {
    min(record_count, workers * 2L)
  }

  task_count <- as.integer(task_count)
  boundaries <- as.integer(floor(seq(
    from = 0,
    to = record_count,
    length.out = task_count + 1L
  )))

  purrr::map(seq_len(task_count), function(task_index) {
    start <- boundaries[[task_index]] + 1L
    end <- boundaries[[task_index + 1L]]
    seq.int(start, end)
  })
}

.require_parallel_packages <- function() {
  required <- c(
    "future",
    "future.mirai",
    "futurize",
    "furrr",
    "mori"
  )
  installed <- purrr::map_lgl(
    required,
    requireNamespace,
    quietly = TRUE
  )
  missing <- required[!installed]

  if (length(missing) > 0L) {
    stop(
      sprintf(
        "Parallel MARCXML parsing requires the following package(s): %s.",
        paste(missing, collapse = ", ")
      ),
      call. = FALSE
    )
  }

  invisible(TRUE)
}

.require_marcxml_stream_packages <- function(workers) {
  packages <- c("XML", "arrow")

  if (workers > 1L) {
    packages <- c(
      packages,
      "future",
      "future.mirai",
      "futurize",
      "furrr",
      "mori"
    )
  }

  installed <- purrr::map_lgl(
    packages,
    requireNamespace,
    quietly = TRUE
  )
  missing <- packages[!installed]

  if (length(missing) > 0L) {
    stop(
      sprintf(
        "Install the following package(s) first: %s.",
        paste(missing, collapse = ", ")
      ),
      call. = FALSE
    )
  }

  invisible(TRUE)
}
