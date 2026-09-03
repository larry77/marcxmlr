.parse_marcxml_record_node <- function(record, record_id) {
  record_id <- .validate_record_id(record_id)

  if (!identical(xml2::xml_name(record), "record")) {
    stop("Expected a MARCXML `<record>` element.", call. = FALSE)
  }

  namespace <- .validate_marc_namespace(
    record,
    sprintf("Record %d", record_id)
  )

  foreign_namespace <- xml2::xml_find_lgl(
    record,
    sprintf(
      "boolean(.//*[namespace-uri(.) != '%s'])",
      namespace
    )
  )

  if (foreign_namespace) {
    stop(
      sprintf("Record %d contains elements from another namespace.", record_id),
      call. = FALSE
    )
  }

  invalid_nesting <- xml2::xml_find_lgl(
    record,
    paste0(
      "boolean(",
      "./*[local-name()='leader' or local-name()='controlfield']/*",
      " | ",
      "./*[local-name()='datafield']/*/*",
      ")"
    )
  )

  if (invalid_nesting) {
    stop(
      sprintf("Record %d contains invalid nested elements.", record_id),
      call. = FALSE
    )
  }

  fields <- xml2::xml_children(record)
  field_names <- xml2::xml_name(fields)
  field_count <- length(fields)

  if (field_count == 0L) {
    stop(sprintf("Record %d is empty.", record_id), call. = FALSE)
  }

  allowed_fields <- c("leader", "controlfield", "datafield")
  unknown_fields <- unique(field_names[!field_names %in% allowed_fields])

  if (length(unknown_fields) > 0L) {
    stop(
      sprintf(
        "Record %d contains unsupported element(s): %s.",
        record_id,
        paste(sprintf("<%s>", unknown_fields), collapse = ", ")
      ),
      call. = FALSE
    )
  }

  leader_positions <- which(field_names == "leader")
  valid_leader <- length(leader_positions) == 1L &&
    leader_positions[[1L]] == 1L

  if (!valid_leader) {
    stop(
      sprintf(
        "Record %d must begin with exactly one `<leader>`.",
        record_id
      ),
      call. = FALSE
    )
  }

  variable_positions <- which(field_names != "leader")
  data_positions <- which(field_names == "datafield")
  atomic_positions <- which(field_names != "datafield")

  tags_by_position <- rep.int(NA_character_, field_count)
  variable_tags <- xml2::xml_attr(fields[variable_positions], "tag")
  invalid_tags <- is.na(variable_tags) | variable_tags == ""

  if (any(invalid_tags)) {
    stop(
      sprintf("Record %d contains a field without a `tag` attribute.", record_id),
      call. = FALSE
    )
  }

  tags_by_position[variable_positions] <- variable_tags

  field_order_by_position <- rep.int(NA_integer_, field_count)
  field_order_by_position[[1L]] <- 0L
  field_order_by_position[variable_positions] <- seq_along(variable_positions)

  field_occurrence_by_position <- rep.int(NA_integer_, field_count)
  field_occurrence_by_position[[1L]] <- 1L
  occurrence_keys <- paste(
    field_names[variable_positions],
    variable_tags,
    sep = "\034"
  )
  field_occurrence_by_position[variable_positions] <-
    .occurrence_number(occurrence_keys)

  ind1_by_position <- rep.int(NA_character_, field_count)
  ind2_by_position <- rep.int(NA_character_, field_count)

  if (length(data_positions) > 0L) {
    data_ind1 <- xml2::xml_attr(fields[data_positions], "ind1")
    data_ind2 <- xml2::xml_attr(fields[data_positions], "ind2")
    invalid_ind1 <- is.na(data_ind1) | data_ind1 == ""
    invalid_ind2 <- is.na(data_ind2) | data_ind2 == ""

    if (any(invalid_ind1)) {
      stop(
        sprintf(
          "Record %d contains a data field without an `ind1` attribute.",
          record_id
        ),
        call. = FALSE
      )
    }

    if (any(invalid_ind2)) {
      stop(
        sprintf(
          "Record %d contains a data field without an `ind2` attribute.",
          record_id
        ),
        call. = FALSE
      )
    }

    ind1_by_position[data_positions] <- data_ind1
    ind2_by_position[data_positions] <- data_ind2
  }

  atomic_values_by_position <- rep.int(NA_character_, field_count)
  atomic_values_by_position[atomic_positions] <- xml2::xml_text(
    fields[atomic_positions],
    trim = FALSE
  )

  rows_by_field <- rep.int(1L, field_count)
  subfield_codes_by_field <- vector("list", field_count)
  subfield_values_by_field <- vector("list", field_count)
  subfield_occurrences_by_field <- vector("list", field_count)

  for (field_position in data_positions) {
    subfields <- xml2::xml_children(fields[[field_position]])
    subfield_count <- length(subfields)

    if (subfield_count == 0L) {
      stop(
        sprintf(
          "Record %d contains a data field without any `<subfield>` elements.",
          record_id
        ),
        call. = FALSE
      )
    }

    subfield_names <- xml2::xml_name(subfields)

    if (any(subfield_names != "subfield")) {
      stop(
        sprintf(
          "Record %d contains a data field with an unsupported child element.",
          record_id
        ),
        call. = FALSE
      )
    }

    codes <- xml2::xml_attr(subfields, "code")
    invalid_codes <- is.na(codes) | codes == ""

    if (any(invalid_codes)) {
      stop(
        sprintf(
          "Record %d contains a subfield without a `code` attribute.",
          record_id
        ),
        call. = FALSE
      )
    }

    subfield_codes_by_field[[field_position]] <- codes
    subfield_values_by_field[[field_position]] <- xml2::xml_text(
      subfields,
      trim = FALSE
    )
    subfield_occurrences_by_field[[field_position]] <-
      .occurrence_number(codes)
    rows_by_field[[field_position]] <- subfield_count
  }

  row_count <- sum(rows_by_field)
  out_record_id <- rep.int(record_id, row_count)
  out_field_type <- rep.int(NA_character_, row_count)
  out_tag <- rep.int(NA_character_, row_count)
  out_subfield_code <- rep.int(NA_character_, row_count)
  out_value <- rep.int(NA_character_, row_count)
  out_field_order <- rep.int(NA_integer_, row_count)
  out_field_occurrence <- rep.int(NA_integer_, row_count)
  out_ind1 <- rep.int(NA_character_, row_count)
  out_ind2 <- rep.int(NA_character_, row_count)
  out_subfield_order <- rep.int(NA_integer_, row_count)
  out_subfield_occurrence <- rep.int(NA_integer_, row_count)
  output_index <- 0L

  for (field_position in seq_len(field_count)) {
    field_type <- field_names[[field_position]]
    field_rows <- rows_by_field[[field_position]]
    output_rows <- output_index + seq_len(field_rows)
    output_index <- output_index + field_rows

    out_field_type[output_rows] <- field_type

    if (field_type == "leader") {
      out_tag[output_rows] <- "LDR"
      out_value[output_rows] <- atomic_values_by_position[[field_position]]
      out_field_order[output_rows] <- 0L
      out_field_occurrence[output_rows] <- 1L
      next
    }

    out_tag[output_rows] <- tags_by_position[[field_position]]
    out_field_order[output_rows] <- field_order_by_position[[field_position]]
    out_field_occurrence[output_rows] <-
      field_occurrence_by_position[[field_position]]

    if (field_type == "controlfield") {
      out_value[output_rows] <- atomic_values_by_position[[field_position]]
      next
    }

    out_subfield_code[output_rows] <-
      subfield_codes_by_field[[field_position]]
    out_value[output_rows] <- subfield_values_by_field[[field_position]]
    out_ind1[output_rows] <- ind1_by_position[[field_position]]
    out_ind2[output_rows] <- ind2_by_position[[field_position]]
    out_subfield_order[output_rows] <- seq_len(field_rows)
    out_subfield_occurrence[output_rows] <-
      subfield_occurrences_by_field[[field_position]]
  }

  tibble::tibble(
    record_id = out_record_id,
    field_type = out_field_type,
    tag = out_tag,
    subfield_code = out_subfield_code,
    value = out_value,
    field_order = out_field_order,
    field_occurrence = out_field_occurrence,
    ind1 = out_ind1,
    ind2 = out_ind2,
    subfield_order = out_subfield_order,
    subfield_occurrence = out_subfield_occurrence
  )
}

#' Parse one serialized MARCXML record
#'
#' This internal function parses one complete MARCXML `record` element. The
#' public readers use it after records have been serialized, which avoids
#' transferring `xml2` external pointers to parallel workers.
#'
#' @param record One non-missing character string containing a complete
#'   MARCXML `record` element.
#' @param record_id Positive integer identity assigned by the parser. This is
#'   independent of control field `001`.
#'
#' @return A tibble using the canonical MARCXML long schema.
#' @keywords internal
parse_marcxml_record <- function(record, record_id = 1L) {
  valid_record <- is.character(record) &&
    length(record) == 1L &&
    !is.na(record)

  if (!valid_record) {
    stop(
      "`record` must be one non-missing XML character string.",
      call. = FALSE
    )
  }

  document <- xml2::read_xml(record)
  root <- xml2::xml_root(document)
  .parse_marcxml_record_node(root, record_id)
}
