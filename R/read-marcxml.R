.parse_marcxml_text_chunk <- function(record_texts, record_ids) {
  parsed <- purrr::map(record_ids, function(record_id) {
    parse_marcxml_record(record_texts[[record_id]], record_id)
  })

  .bind_marcxml_results(parsed)
}

.extract_marcxml_record_texts <- function(file, n_max) {
  document <- xml2::read_xml(file)
  root <- xml2::xml_root(document)
  root_name <- xml2::xml_name(root)
  root_namespace <- .validate_marc_namespace(root, "Document root")

  if (root_name == "record") {
    records <- xml2::xml_find_all(document, "/*")
  } else if (root_name == "collection") {
    records <- xml2::xml_children(root)
    record_names <- xml2::xml_name(records)
    record_namespaces <- xml2::xml_find_chr(
      records,
      "namespace-uri(.)"
    )
    invalid_records <- record_names != "record" |
      record_namespaces != root_namespace

    if (any(invalid_records)) {
      stop(
        paste0(
          "A MARCXML `<collection>` may contain only ",
          "`<record>` elements in the collection namespace."
        ),
        call. = FALSE
      )
    }
  } else {
    stop(
      sprintf(
        paste0(
          "Document root is <%s>; expected a MARCXML ",
          "`<collection>` or standalone `<record>`."
        ),
        root_name
      ),
      call. = FALSE
    )
  }

  record_count <- length(records)
  selected_count <- if (is.infinite(n_max)) {
    record_count
  } else {
    as.integer(min(record_count, n_max))
  }

  if (selected_count == 0L) {
    return(character())
  }

  purrr::map_chr(seq_len(selected_count), function(record_id) {
    .ensure_record_namespace(
      as.character(records[[record_id]]),
      root_namespace
    )
  })
}

#' Read MARCXML into a canonical long tibble
#'
#' `read_marcxml()` reads a MARC21 XML collection or a standalone record and
#' returns one row for each leader, control field, or data-field subfield. It
#' preserves repeated fields, repeated subfields, indicators, and source order.
#'
#' This function materializes both the XML input and the parsed result in
#' memory. Use [marcxml_to_parquet()] for catalogues that may not fit in memory.
#'
#' @param file Path to a MARCXML file.
#' @param n_max Maximum number of records to parse. Use `Inf` for every record
#'   or `0` to return an empty result with the canonical schema.
#' @param workers Number of local worker processes. The default, `1`, is
#'   sequential. Values greater than one require the optional parallel
#'   packages listed in `Suggests`.
#' @param chunk_records Number of records assigned to each parsing task. `NULL`
#'   creates one task in sequential mode and approximately two tasks per worker
#'   in parallel mode.
#'
#' @return A tibble with columns `record_id`, `field_type`, `tag`,
#'   `subfield_code`, `value`, `field_order`, `field_occurrence`, `ind1`,
#'   `ind2`, `subfield_order`, and `subfield_occurrence`, in that order.
#'
#' @details
#' `record_id` is the record's positional identity in the input selected for
#' parsing; it is not derived from control field `001`. `field_order` is zero
#' for the leader and then counts variable fields from one. `field_occurrence`
#' counts occurrences of a field type and tag within a record.
#'
#' Data-field rows carry `subfield_order`, the position of the subfield within
#' its containing field, and `subfield_occurrence`, the occurrence of that code
#' within the same field. Structural columns that do not apply to leaders or
#' control fields are `NA`.
#'
#' Parallel parsing serializes complete records before dispatch. `xml2`
#' external pointers are never sent to worker processes. The caller's previous
#' future plan is restored when parsing finishes or fails.
#'
#' @examples
#' example_file <- system.file(
#'   "extdata", "example-marcxml.xml", package = "marcxmlr"
#' )
#'
#' records <- read_marcxml(example_file)
#' records
#'
#' # Inspect repeated subfields without collapsing them.
#' records[
#'   records$record_id == 1L & records$tag == "856",
#'   c("subfield_code", "value", "subfield_order", "subfield_occurrence")
#' ]
#'
#' @export
read_marcxml <- function(
  file,
  n_max = Inf,
  workers = 1L,
  chunk_records = NULL
) {
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

  n_max <- .validate_n_max(n_max)
  workers <- .validate_workers(workers)
  chunk_records <- .validate_chunk_records(chunk_records)
  record_texts <- .extract_marcxml_record_texts(file = file, n_max = n_max)
  record_count <- length(record_texts)

  if (record_count == 0L) {
    return(.empty_marcxml())
  }

  effective_workers <- min(workers, record_count)
  record_chunks <- .make_record_chunks(
    record_count = record_count,
    workers = effective_workers,
    chunk_records = chunk_records
  )

  if (effective_workers == 1L) {
    parsed_chunks <- purrr::map(record_chunks, function(record_ids) {
      .parse_marcxml_text_chunk(record_texts, record_ids)
    })

    return(.bind_marcxml_results(parsed_chunks))
  }

  .require_parallel_packages()
  previous_plan <- future::plan(
    future.mirai::mirai_multisession,
    workers = effective_workers
  )
  on.exit(future::plan(previous_plan), add = TRUE)
  shared_record_texts <- mori::share(record_texts)

  parsed_chunks <- purrr::map(record_chunks, function(record_ids) {
    .parse_marcxml_text_chunk(shared_record_texts, record_ids)
  }) |>
    futurize::futurize()

  .bind_marcxml_results(parsed_chunks)
}
