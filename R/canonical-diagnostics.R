.writer_canonical_columns <- c(
  "record_id",
  "field_type",
  "tag",
  "subfield_code",
  "value",
  "field_order",
  "field_occurrence",
  "ind1",
  "ind2",
  "subfield_order",
  "subfield_occurrence"
)

.writer_empty_diagnostics <- function() {
  tibble::tibble(
    severity = character(),
    code = character(),
    message = character(),
    record_id = integer(),
    field_order = integer(),
    subfield_order = integer()
  )
}

.writer_diagnostic_issue <- function(
  severity,
  code,
  message,
  record_id = NA_integer_,
  field_order = NA_integer_,
  subfield_order = NA_integer_
) {
  tibble::tibble(
    severity = severity,
    code = code,
    message = message,
    record_id = as.integer(record_id),
    field_order = as.integer(field_order),
    subfield_order = as.integer(subfield_order)
  )
}

.writer_add_issue <- function(
  issues,
  severity,
  code,
  message,
  record_id = NA_integer_,
  field_order = NA_integer_,
  subfield_order = NA_integer_
) {
  issues[[length(issues) + 1L]] <- .writer_diagnostic_issue(
    severity,
    code,
    message,
    record_id,
    field_order,
    subfield_order
  )
  issues
}

.writer_bind_issues <- function(issues) {
  if (length(issues) == 0L) {
    return(.writer_empty_diagnostics())
  }

  out <- do.call(rbind, issues)
  rownames(out) <- NULL
  tibble::as_tibble(out)
}

.writer_has_errors <- function(issues) {
  any(vapply(
    issues,
    function(issue) issue$severity[[1L]] == "error",
    logical(1)
  ))
}

.writer_is_integerish <- function(x, allow_na = TRUE) {
  if (!is.numeric(x)) {
    return(FALSE)
  }

  if (!allow_na && anyNA(x)) {
    return(FALSE)
  }

  ok <- is.na(x) | (
    is.finite(x) &
      x == floor(x) &
      abs(x) <= .Machine$integer.max
  )
  all(ok)
}

.writer_occurrence_matches <- function(x, expected) {
  is.numeric(x) &&
    length(x) == length(expected) &&
    .writer_is_integerish(x, allow_na = FALSE) &&
    all(x > 0) &&
    identical(as.integer(x), as.integer(expected))
}

.writer_xml10_string_ok <- function(value) {
  if (is.na(value)) {
    return(TRUE)
  }

  codepoints <- tryCatch(
    utf8ToInt(enc2utf8(value)),
    warning = function(cnd) NA_integer_,
    error = function(cnd) NA_integer_
  )

  if (anyNA(codepoints)) {
    return(FALSE)
  }

  all(
    codepoints == 9L |
      codepoints == 10L |
      codepoints == 13L |
      (codepoints >= 32L & codepoints <= 55295L) |
      (codepoints >= 57344L & codepoints <= 65533L) |
      (codepoints >= 65536L & codepoints <= 1114111L)
  )
}

#' Diagnose a canonical MARC representation
#'
#' Check whether an in-memory canonical `marcxmlr` representation contains
#' enough unambiguous structure to be serialized as MARCXML. Structural
#' problems are reported as errors. Stale or gapped analytical coordinates
#' that can be regenerated after writing and rereading are reported as
#' warnings.
#'
#' This function diagnoses the canonical representation used by `marcxmlr`.
#' It is not a complete MARC cataloguing validator and does not repair `x`.
#'
#' @param x A data frame or tibble containing the canonical 11-column
#'   `marcxmlr` representation. Additional columns are ignored.
#'
#' @return A tibble with columns `severity`, `code`, `message`, `record_id`,
#'   `field_order`, and `subfield_order`. A clean canonical representation
#'   returns a zero-row tibble.
#'
#' @export
#'
#' @examples
#' example_file <- system.file(
#'   "extdata", "example-marcxml.xml", package = "marcxmlr"
#' )
#' x <- read_marcxml(example_file)
#' diagnose_canonical(x)
diagnose_canonical <- function(x) {
  .writer_diagnose_impl(x, include_warnings = TRUE)
}

.writer_diagnose_impl <- function(x, include_warnings = TRUE) {
  issues <- list()

  if (!is.data.frame(x)) {
    return(.writer_diagnostic_issue(
      "error",
      "input_not_data_frame",
      "`x` must be a data.frame or tibble."
    ))
  }

  missing_columns <- setdiff(.writer_canonical_columns, names(x))
  duplicate_columns <- .writer_canonical_columns[
    vapply(
      .writer_canonical_columns,
      function(nm) sum(names(x) == nm) > 1L,
      logical(1)
    )
  ]

  if (length(missing_columns) > 0L) {
    issues <- .writer_add_issue(
      issues,
      "error",
      "missing_columns",
      paste0(
        "Missing required canonical column(s): ",
        paste(missing_columns, collapse = ", "),
        "."
      )
    )
  }

  if (length(duplicate_columns) > 0L) {
    issues <- .writer_add_issue(
      issues,
      "error",
      "duplicate_columns",
      paste0(
        "Canonical column name(s) occur more than once: ",
        paste(duplicate_columns, collapse = ", "),
        "."
      )
    )
  }

  if (.writer_has_errors(issues)) {
    return(.writer_bind_issues(issues))
  }

  character_columns <- c(
    "field_type", "tag", "subfield_code", "value", "ind1", "ind2"
  )
  structural_coordinates <- c("record_id", "field_order", "subfield_order")

  for (nm in character_columns) {
    if (!is.character(x[[nm]])) {
      issues <- .writer_add_issue(
        issues,
        "error",
        "invalid_column_type",
        sprintf("Canonical column `%s` must be character.", nm)
      )
    }
  }

  for (nm in structural_coordinates) {
    if (!.writer_is_integerish(x[[nm]], allow_na = TRUE)) {
      issues <- .writer_add_issue(
        issues,
        "error",
        "invalid_column_type",
        sprintf(
          "Canonical coordinate `%s` must contain integer-like numeric values or NA.",
          nm
        )
      )
    }
  }

  if (.writer_has_errors(issues)) {
    return(.writer_bind_issues(issues))
  }

  if (nrow(x) == 0L) {
    return(.writer_bind_issues(issues))
  }

  record_id <- as.integer(x$record_id)
  field_order <- as.integer(x$field_order)
  subfield_order <- as.integer(x$subfield_order)

  if (anyNA(record_id) || any(record_id <= 0L)) {
    issues <- .writer_add_issue(
      issues,
      "error",
      "invalid_record_id",
      "`record_id` must be non-missing and positive for every row."
    )
  }

  if (anyNA(field_order) || any(field_order < 0L)) {
    issues <- .writer_add_issue(
      issues,
      "error",
      "invalid_field_order",
      "`field_order` must be non-missing and non-negative for every row."
    )
  }

  if (anyNA(x$field_type) ||
      any(!x$field_type %in% c("leader", "controlfield", "datafield"))) {
    issues <- .writer_add_issue(
      issues,
      "error",
      "invalid_field_type",
      "`field_type` must be `leader`, `controlfield`, or `datafield`."
    )
  }

  if (anyNA(x$tag) || any(x$tag == "", na.rm = TRUE)) {
    issues <- .writer_add_issue(
      issues,
      "error",
      "missing_tag",
      "`tag` must be non-missing and non-empty for every row."
    )
  }

  if (anyNA(x$value)) {
    issues <- .writer_add_issue(
      issues,
      "error",
      "missing_value",
      "`value` must be non-missing; empty strings are allowed."
    )
  }

  if (.writer_has_errors(issues)) {
    return(.writer_bind_issues(issues))
  }

  is_data <- x$field_type == "datafield"
  is_leader <- x$field_type == "leader"
  is_non_data <- !is_data

  if (any(is_data & (is.na(x$subfield_code) | x$subfield_code == ""))) {
    issues <- .writer_add_issue(
      issues,
      "error",
      "missing_subfield_code",
      "Every datafield row must have a non-missing, non-empty `subfield_code`."
    )
  }

  if (any(is_data & (is.na(x$ind1) | x$ind1 == "")) ||
      any(is_data & (is.na(x$ind2) | x$ind2 == ""))) {
    issues <- .writer_add_issue(
      issues,
      "error",
      "missing_indicator",
      paste0(
        "Every datafield row must have non-missing, non-empty `ind1` and `ind2`; ",
        "a blank indicator is represented by a single space."
      )
    )
  }

  bad_subfield_order <- is_data & (
    is.na(subfield_order) | subfield_order <= 0L
  )
  if (any(bad_subfield_order)) {
    issues <- .writer_add_issue(
      issues,
      "error",
      "invalid_subfield_order",
      "Every datafield row must have a positive `subfield_order`."
    )
  }

  if (any(is_non_data & !is.na(x$subfield_code))) {
    issues <- .writer_add_issue(
      issues,
      "error",
      "unexpected_subfield_code",
      "Leader and controlfield rows must have `subfield_code = NA`."
    )
  }

  if (any(is_non_data & (!is.na(x$ind1) | !is.na(x$ind2)))) {
    issues <- .writer_add_issue(
      issues,
      "error",
      "unexpected_indicators",
      "Leader and controlfield rows must have `ind1 = NA` and `ind2 = NA`."
    )
  }

  if (any(is_leader & x$tag != "LDR")) {
    issues <- .writer_add_issue(
      issues,
      "error",
      "invalid_leader_tag",
      "Leader rows must use tag `LDR`."
    )
  }

  for (i in seq_len(nrow(x))) {
    xml_columns <- switch(
      x$field_type[[i]],
      leader = "value",
      controlfield = c("tag", "value"),
      datafield = c("tag", "value", "subfield_code", "ind1", "ind2")
    )

    bad_columns <- xml_columns[!vapply(
      xml_columns,
      function(nm) .writer_xml10_string_ok(x[[nm]][[i]]),
      logical(1)
    )]

    if (length(bad_columns) > 0L) {
      issues <- .writer_add_issue(
        issues,
        "error",
        "invalid_xml_character",
        sprintf(
          paste0(
            "Record %d field_order %d contains text that cannot be represented ",
            "safely in UTF-8 XML 1.0 in column(s): %s."
          ),
          record_id[[i]],
          field_order[[i]],
          paste(bad_columns, collapse = ", ")
        ),
        record_id = record_id[[i]],
        field_order = field_order[[i]],
        subfield_order = if (is_data[[i]]) subfield_order[[i]] else NA_integer_
      )
    }
  }

  if (.writer_has_errors(issues)) {
    return(.writer_bind_issues(issues))
  }

  record_ids <- sort(unique(record_id))

  for (rid in record_ids) {
    idx_record <- which(record_id == rid)
    leader_rows <- idx_record[is_leader[idx_record]]

    if (length(leader_rows) != 1L) {
      issues <- .writer_add_issue(
        issues,
        "error",
        "leader_count",
        sprintf(
          "Record %d must contain exactly one leader row; found %d.",
          rid,
          length(leader_rows)
        ),
        record_id = rid
      )
    } else if (field_order[leader_rows] != 0L) {
      issues <- .writer_add_issue(
        issues,
        "error",
        "leader_order",
        sprintf("Record %d leader must have `field_order = 0`.", rid),
        record_id = rid,
        field_order = field_order[leader_rows]
      )
    }

    if (any(!is_leader[idx_record] & field_order[idx_record] == 0L)) {
      issues <- .writer_add_issue(
        issues,
        "error",
        "field_order_zero_reserved",
        sprintf("Record %d uses `field_order = 0` for a non-leader field.", rid),
        record_id = rid,
        field_order = 0L
      )
    }
  }

  field_key <- paste(record_id, field_order, sep = "\034")
  field_groups <- split(seq_len(nrow(x)), field_key, drop = TRUE)

  for (idx in field_groups) {
    rid <- record_id[idx[[1L]]]
    order_value <- field_order[idx[[1L]]]
    types <- unique(x$field_type[idx])
    tags <- unique(x$tag[idx])

    if (length(types) != 1L) {
      issues <- .writer_add_issue(
        issues,
        "error",
        "conflicting_field_type",
        sprintf(
          "Record %d field_order %d contains conflicting `field_type` values.",
          rid,
          order_value
        ),
        record_id = rid,
        field_order = order_value
      )
      next
    }

    if (length(tags) != 1L) {
      issues <- .writer_add_issue(
        issues,
        "error",
        "conflicting_tag",
        sprintf(
          "Record %d field_order %d contains conflicting tags.",
          rid,
          order_value
        ),
        record_id = rid,
        field_order = order_value
      )
    }

    if (types[[1L]] == "datafield") {
      if (length(unique(x$ind1[idx])) != 1L ||
          length(unique(x$ind2[idx])) != 1L) {
        issues <- .writer_add_issue(
          issues,
          "error",
          "conflicting_indicators",
          sprintf(
            "Record %d field_order %d contains conflicting indicators.",
            rid,
            order_value
          ),
          record_id = rid,
          field_order = order_value
        )
      }

      if (anyDuplicated(subfield_order[idx])) {
        issues <- .writer_add_issue(
          issues,
          "error",
          "duplicate_subfield_order",
          sprintf(
            "Record %d field_order %d contains duplicate `subfield_order` values.",
            rid,
            order_value
          ),
          record_id = rid,
          field_order = order_value
        )
      }
    } else if (length(idx) != 1L) {
      issues <- .writer_add_issue(
        issues,
        "error",
        "multiple_rows_for_scalar_field",
        sprintf(
          "Record %d field_order %d represents a %s but contains %d rows.",
          rid,
          order_value,
          types[[1L]],
          length(idx)
        ),
        record_id = rid,
        field_order = order_value
      )
    }
  }

  if (!.writer_has_errors(issues)) {
    for (rid in record_ids) {
      field_orders_rid <- sort(unique(field_order[record_id == rid]))
      seen_datafield <- FALSE

      for (order_value in field_orders_rid) {
        idx <- which(record_id == rid & field_order == order_value)
        field_type_value <- x$field_type[[idx[[1L]]]]

        if (field_type_value == "datafield") {
          seen_datafield <- TRUE
        } else if (field_type_value == "controlfield" && seen_datafield) {
          issues <- .writer_add_issue(
            issues,
            "error",
            "field_type_order",
            sprintf(
              paste0(
                "Record %d has a controlfield after a datafield in `field_order`; ",
                "MARCXML requires controlfields to precede datafields."
              ),
              rid
            ),
            record_id = rid,
            field_order = order_value
          )
          break
        }
      }
    }
  }

  if (.writer_has_errors(issues) || !isTRUE(include_warnings)) {
    return(.writer_bind_issues(issues))
  }

  if (!identical(record_ids, seq_along(record_ids))) {
    issues <- .writer_add_issue(
      issues,
      "warning",
      "record_id_will_renumber",
      paste0(
        "`record_id` values are not contiguous from 1; they will be regenerated ",
        "when the written XML is reread."
      )
    )
  }

  if (!all(is.na(subfield_order[is_non_data]))) {
    issues <- .writer_add_issue(
      issues,
      "warning",
      "non_applicable_subfield_order",
      paste0(
        "Leader or controlfield rows contain non-NA `subfield_order` values; ",
        "these analytical coordinates are not represented in MARCXML and will be lost."
      )
    )
  }

  if (!all(is.na(x$subfield_occurrence[is_non_data]))) {
    issues <- .writer_add_issue(
      issues,
      "warning",
      "non_applicable_subfield_occurrence",
      paste0(
        "Leader or controlfield rows contain non-NA `subfield_occurrence` values; ",
        "these analytical coordinates are not represented in MARCXML and will be lost."
      )
    )
  }

  for (rid in record_ids) {
    idx_record <- which(record_id == rid)
    field_orders <- sort(unique(field_order[idx_record]))

    if (!identical(field_orders, seq.int(0L, length(field_orders) - 1L))) {
      issues <- .writer_add_issue(
        issues,
        "warning",
        "field_order_will_renumber",
        sprintf(
          paste0(
            "Record %d has gaps or stale values in `field_order`; field positions ",
            "will be regenerated when the written XML is reread."
          ),
          rid
        ),
        record_id = rid
      )
    }

    field_counts <- new.env(parent = emptyenv())

    for (order_value in field_orders) {
      idx <- which(record_id == rid & field_order == order_value)
      field_type <- x$field_type[idx[[1L]]]
      tag <- x$tag[idx[[1L]]]
      occurrence_key <- paste(field_type, tag, sep = "\034")

      old <- if (exists(occurrence_key, field_counts, inherits = FALSE)) {
        get(occurrence_key, field_counts, inherits = FALSE)
      } else {
        0L
      }
      expected <- old + 1L
      assign(occurrence_key, expected, field_counts)

      if (!.writer_occurrence_matches(x$field_occurrence[idx], rep(expected, length(idx)))) {
        issues <- .writer_add_issue(
          issues,
          "warning",
          "field_occurrence_stale",
          sprintf(
            "Record %d field_order %d has stale `field_occurrence` values.",
            rid,
            order_value
          ),
          record_id = rid,
          field_order = order_value
        )
      }

      if (field_type != "datafield") {
        next
      }

      idx <- idx[order(subfield_order[idx])]
      observed_order <- subfield_order[idx]
      expected_order <- seq_along(idx)

      if (!identical(observed_order, as.integer(expected_order))) {
        issues <- .writer_add_issue(
          issues,
          "warning",
          "subfield_order_will_renumber",
          sprintf(
            paste0(
              "Record %d field_order %d has gaps or stale values in `subfield_order`; ",
              "subfield positions will be regenerated when the written XML is reread."
            ),
            rid,
            order_value
          ),
          record_id = rid,
          field_order = order_value
        )
      }

      expected_occurrence <- integer(length(idx))
      subfield_counts <- new.env(parent = emptyenv())

      for (j in seq_along(idx)) {
        code <- x$subfield_code[[idx[[j]]]]
        old <- if (exists(code, subfield_counts, inherits = FALSE)) {
          get(code, subfield_counts, inherits = FALSE)
        } else {
          0L
        }
        expected_occurrence[[j]] <- old + 1L
        assign(code, expected_occurrence[[j]], subfield_counts)
      }

      if (!.writer_occurrence_matches(
        x$subfield_occurrence[idx],
        expected_occurrence
      )) {
        issues <- .writer_add_issue(
          issues,
          "warning",
          "subfield_occurrence_stale",
          sprintf(
            "Record %d field_order %d has stale `subfield_occurrence` values.",
            rid,
            order_value
          ),
          record_id = rid,
          field_order = order_value
        )
      }
    }
  }

  .writer_bind_issues(issues)
}
