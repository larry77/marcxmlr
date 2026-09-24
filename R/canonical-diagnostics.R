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

.writer_rank_within_key <- function(key) {
  n <- length(key)
  if (n == 0L) {
    return(integer())
  }

  ord <- order(key, method = "radix")
  sorted_key <- key[ord]
  starts <- c(TRUE, sorted_key[-1L] != sorted_key[-n])
  sizes <- diff(c(which(starts), n + 1L))

  ranked <- integer(n)
  ranked[ord] <- sequence(sizes)
  ranked
}

.writer_xml10_invalid <- function(value) {
  out <- rep(FALSE, length(value))
  idx <- which(!is.na(value))

  if (length(idx) == 0L) {
    return(out)
  }

  text <- enc2utf8(value[idx])
  char_length <- suppressWarnings(nchar(text, type = "chars", allowNA = TRUE))
  bad <- is.na(char_length)
  valid <- !bad

  if (any(valid)) {
    text_valid <- text[valid]
    bad[valid] <-
      grepl(
        "[\\x00-\\x08\\x0B\\x0C\\x0E-\\x1F]",
        text_valid,
        perl = TRUE,
        useBytes = TRUE
      ) |
      grepl(
        intToUtf8(0xFFFE),
        text_valid,
        fixed = TRUE,
        useBytes = TRUE
      ) |
      grepl(
        intToUtf8(0xFFFF),
        text_valid,
        fixed = TRUE,
        useBytes = TRUE
      )
  }

  out[idx] <- bad
  out
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

  xml_bad <- list(
    tag = .writer_xml10_invalid(x$tag),
    value = .writer_xml10_invalid(x$value),
    subfield_code = .writer_xml10_invalid(x$subfield_code),
    ind1 = .writer_xml10_invalid(x$ind1),
    ind2 = .writer_xml10_invalid(x$ind2)
  )

  xml_bad_rows <-
    xml_bad$value |
    (!is_leader & xml_bad$tag) |
    (is_data & (
      xml_bad$subfield_code | xml_bad$ind1 | xml_bad$ind2
    ))

  for (i in which(xml_bad_rows)) {
    xml_columns <- if (is_leader[[i]]) {
      "value"
    } else if (is_data[[i]]) {
      c("tag", "value", "subfield_code", "ind1", "ind2")
    } else {
      c("tag", "value")
    }

    bad_columns <- xml_columns[vapply(
      xml_columns,
      function(nm) xml_bad[[nm]][[i]],
      logical(1)
    )]

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

  if (.writer_has_errors(issues)) {
    return(.writer_bind_issues(issues))
  }

  record_ids <- sort(unique(record_id))
  n_records <- length(record_ids)
  record_index <- match(record_id, record_ids)

  leader_counts <- tabulate(record_index[is_leader], nbins = n_records)
  leader_rows <- which(is_leader)
  leader_row_by_record <- rep(NA_integer_, n_records)
  if (length(leader_rows) > 0L) {
    leader_row_by_record[record_index[leader_rows]] <- leader_rows
  }

  bad_leader_count <- which(leader_counts != 1L)
  for (record_pos in bad_leader_count) {
    rid <- record_ids[[record_pos]]
    issues <- .writer_add_issue(
      issues,
      "error",
      "leader_count",
      sprintf(
        "Record %d must contain exactly one leader row; found %d.",
        rid,
        leader_counts[[record_pos]]
      ),
      record_id = rid
    )
  }

  one_leader <- which(leader_counts == 1L)
  if (length(one_leader) > 0L) {
    leader_idx <- leader_row_by_record[one_leader]
    bad_leader_order <- one_leader[field_order[leader_idx] != 0L]

    for (record_pos in bad_leader_order) {
      rid <- record_ids[[record_pos]]
      idx <- leader_row_by_record[[record_pos]]
      issues <- .writer_add_issue(
        issues,
        "error",
        "leader_order",
        sprintf("Record %d leader must have `field_order = 0`.", rid),
        record_id = rid,
        field_order = field_order[[idx]]
      )
    }
  }

  zero_non_leader_records <- unique(record_id[!is_leader & field_order == 0L])
  zero_non_leader_records <- sort(zero_non_leader_records)
  for (rid in zero_non_leader_records) {
    issues <- .writer_add_issue(
      issues,
      "error",
      "field_order_zero_reserved",
      sprintf("Record %d uses `field_order = 0` for a non-leader field.", rid),
      record_id = rid,
      field_order = 0L
    )
  }

  # Build one ordered structural index and reuse it for all group-level checks.
  # This avoids repeated full-table scans and thousands of tiny split/data-frame
  # operations for large canonical representations.
  subfield_sort <- ifelse(is_data, subfield_order, 0L)
  row_order <- order(
    record_id,
    field_order,
    subfield_sort,
    seq_len(nrow(x)),
    method = "radix"
  )

  record_sorted <- record_id[row_order]
  field_order_sorted <- field_order[row_order]
  subfield_order_sorted <- subfield_order[row_order]
  type_sorted <- x$field_type[row_order]
  tag_sorted <- x$tag[row_order]
  ind1_sorted <- x$ind1[row_order]
  ind2_sorted <- x$ind2[row_order]

  n_rows <- length(row_order)
  new_field_group <- c(
    TRUE,
    record_sorted[-1L] != record_sorted[-n_rows] |
      field_order_sorted[-1L] != field_order_sorted[-n_rows]
  )
  group_id_sorted <- cumsum(new_field_group)
  group_starts <- which(new_field_group)
  group_ends <- c(group_starts[-1L] - 1L, n_rows)
  group_sizes <- group_ends - group_starts + 1L
  group_first_rows <- row_order[group_starts]
  n_groups <- length(group_starts)

  group_record <- record_id[group_first_rows]
  group_field_order <- field_order[group_first_rows]
  group_type <- x$field_type[group_first_rows]
  group_tag <- x$tag[group_first_rows]
  group_ind1 <- x$ind1[group_first_rows]
  group_ind2 <- x$ind2[group_first_rows]

  type_conflict <- tabulate(
    group_id_sorted[type_sorted != group_type[group_id_sorted]],
    nbins = n_groups
  ) > 0L
  tag_conflict <- tabulate(
    group_id_sorted[tag_sorted != group_tag[group_id_sorted]],
    nbins = n_groups
  ) > 0L

  group_is_data <- group_type == "datafield"
  valid_type_group <- !type_conflict
  data_rows_sorted <- group_is_data[group_id_sorted] &
    valid_type_group[group_id_sorted]

  indicator_conflict_rows <- data_rows_sorted & (
    ind1_sorted != group_ind1[group_id_sorted] |
      ind2_sorted != group_ind2[group_id_sorted]
  )
  indicator_conflict <- tabulate(
    group_id_sorted[indicator_conflict_rows],
    nbins = n_groups
  ) > 0L

  same_group_as_previous <- c(
    FALSE,
    group_id_sorted[-1L] == group_id_sorted[-n_rows]
  )
  duplicate_subfield_rows <- data_rows_sorted &
    same_group_as_previous &
    !is.na(subfield_order_sorted) &
    subfield_order_sorted == c(NA_integer_, subfield_order_sorted[-n_rows])
  duplicate_subfield_order <- tabulate(
    group_id_sorted[duplicate_subfield_rows],
    nbins = n_groups
  ) > 0L

  multiple_scalar_rows <- valid_type_group &
    !group_is_data &
    group_sizes != 1L

  bad_groups <- which(
    type_conflict |
      tag_conflict |
      indicator_conflict |
      duplicate_subfield_order |
      multiple_scalar_rows
  )

  for (group_id in bad_groups) {
    rid <- group_record[[group_id]]
    order_value <- group_field_order[[group_id]]

    if (type_conflict[[group_id]]) {
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

    if (tag_conflict[[group_id]]) {
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

    if (group_is_data[[group_id]]) {
      if (indicator_conflict[[group_id]]) {
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

      if (duplicate_subfield_order[[group_id]]) {
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
    } else if (multiple_scalar_rows[[group_id]]) {
      issues <- .writer_add_issue(
        issues,
        "error",
        "multiple_rows_for_scalar_field",
        sprintf(
          "Record %d field_order %d represents a %s but contains %d rows.",
          rid,
          order_value,
          group_type[[group_id]],
          group_sizes[[group_id]]
        ),
        record_id = rid,
        field_order = order_value
      )
    }
  }

  group_record_start <- c(
    TRUE,
    group_record[-1L] != group_record[-n_groups]
  )
  record_group_starts <- which(group_record_start)
  record_group_ends <- c(record_group_starts[-1L] - 1L, n_groups)

  if (!.writer_has_errors(issues)) {
    for (record_pos in seq_len(n_records)) {
      groups <- record_group_starts[[record_pos]]:record_group_ends[[record_pos]]
      types <- group_type[groups]
      first_data <- match("datafield", types, nomatch = 0L)

      if (first_data == 0L) {
        next
      }

      later_control <- which(
        seq_along(types) > first_data & types == "controlfield"
      )
      if (length(later_control) == 0L) {
        next
      }

      group_id <- groups[[later_control[[1L]]]]
      rid <- group_record[[group_id]]
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
        field_order = group_field_order[[group_id]]
      )
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

  field_order_warning <- logical(n_records)
  for (record_pos in seq_len(n_records)) {
    groups <- record_group_starts[[record_pos]]:record_group_ends[[record_pos]]
    observed <- group_field_order[groups]
    field_order_warning[[record_pos]] <- !identical(
      observed,
      seq.int(0L, length(observed) - 1L)
    )
  }

  occurrence_key <- paste(
    group_record,
    group_type,
    group_tag,
    sep = "\034"
  )
  expected_field_occurrence <- .writer_rank_within_key(occurrence_key)

  if (!is.numeric(x$field_occurrence)) {
    field_occurrence_warning <- rep(TRUE, n_groups)
  } else {
    observed <- x$field_occurrence[row_order]
    expected <- expected_field_occurrence[group_id_sorted]
    bad <- is.na(observed) |
      !is.finite(observed) |
      observed <= 0 |
      abs(observed) > .Machine$integer.max |
      observed != floor(observed)
    ok <- !bad
    bad[ok] <- as.integer(observed[ok]) != expected[ok]
    field_occurrence_warning <- tabulate(
      group_id_sorted[bad],
      nbins = n_groups
    ) > 0L
  }

  position_within_group <- sequence(group_sizes)
  subfield_order_bad <- data_rows_sorted &
    subfield_order_sorted != position_within_group
  subfield_order_warning <- tabulate(
    group_id_sorted[subfield_order_bad],
    nbins = n_groups
  ) > 0L

  data_positions <- which(data_rows_sorted)
  subfield_occurrence_warning <- rep(FALSE, n_groups)
  if (length(data_positions) > 0L) {
    subfield_key <- paste(
      group_id_sorted[data_positions],
      x$subfield_code[row_order[data_positions]],
      sep = "\034"
    )
    expected_subfield_occurrence <- .writer_rank_within_key(subfield_key)

    if (!is.numeric(x$subfield_occurrence)) {
      subfield_occurrence_warning[group_id_sorted[data_positions]] <- TRUE
    } else {
      observed <- x$subfield_occurrence[row_order[data_positions]]
      bad <- is.na(observed) |
        !is.finite(observed) |
        observed <= 0 |
        abs(observed) > .Machine$integer.max |
        observed != floor(observed)
      ok <- !bad
      bad[ok] <- as.integer(observed[ok]) != expected_subfield_occurrence[ok]
      bad_groups_subfield <- unique(group_id_sorted[data_positions[bad]])
      subfield_occurrence_warning[bad_groups_subfield] <- TRUE
    }
  }

  any_group_warning <- field_occurrence_warning |
    subfield_order_warning |
    subfield_occurrence_warning

  for (record_pos in seq_len(n_records)) {
    rid <- record_ids[[record_pos]]

    if (field_order_warning[[record_pos]]) {
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

    groups <- record_group_starts[[record_pos]]:record_group_ends[[record_pos]]
    groups <- groups[any_group_warning[groups]]

    for (group_id in groups) {
      order_value <- group_field_order[[group_id]]

      if (field_occurrence_warning[[group_id]]) {
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

      if (!group_is_data[[group_id]]) {
        next
      }

      if (subfield_order_warning[[group_id]]) {
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

      if (subfield_occurrence_warning[[group_id]]) {
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
