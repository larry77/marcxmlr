.writer_format_condition <- function(diagnostics, heading, max_items = 8L) {
  total <- nrow(diagnostics)
  shown <- diagnostics[seq_len(min(total, max_items)), , drop = FALSE]
  bullets <- paste0("- ", shown$message)
  omitted <- total - nrow(shown)

  if (omitted > 0L) {
    bullets <- c(bullets, sprintf("- ... and %d more issue(s).", omitted))
  }

  paste(c(heading, bullets), collapse = "\n")
}

.writer_abort_errors <- function(diagnostics) {
  errors <- diagnostics[diagnostics$severity == "error", , drop = FALSE]
  if (nrow(errors) == 0L) {
    return(invisible(NULL))
  }

  rlang::abort(
    .writer_format_condition(
      errors,
      "Canonical representation is not structurally safe to serialize:"
    ),
    class = "marcxmlr_canonical_error",
    diagnostics = errors
  )
}

.writer_warn_warnings <- function(diagnostics) {
  warnings <- diagnostics[diagnostics$severity == "warning", , drop = FALSE]
  if (nrow(warnings) == 0L) {
    return(invisible(NULL))
  }

  rlang::warn(
    .writer_format_condition(
      warnings,
      paste0(
        "Canonical representation can be serialized, but derived analytical ",
        "coordinates will be regenerated on reread:"
      )
    ),
    class = "marcxmlr_canonical_warning",
    diagnostics = warnings
  )
}

.writer_validate_args <- function(file, check, pretty, records_per_file) {
  if (!is.character(file) || length(file) != 1L || is.na(file) || file == "") {
    rlang::abort(
      "`file` must be one non-empty path.",
      class = "marcxmlr_argument_error"
    )
  }

  if (!is.logical(check) || length(check) != 1L || is.na(check)) {
    rlang::abort("`check` must be TRUE or FALSE.", class = "marcxmlr_argument_error")
  }

  if (!is.logical(pretty) || length(pretty) != 1L || is.na(pretty)) {
    rlang::abort("`pretty` must be TRUE or FALSE.", class = "marcxmlr_argument_error")
  }

  finite_count <-
    is.numeric(records_per_file) &&
    length(records_per_file) == 1L &&
    !is.na(records_per_file) &&
    is.finite(records_per_file) &&
    records_per_file > 0 &&
    records_per_file == floor(records_per_file) &&
    records_per_file <= .Machine$integer.max

  infinite_count <-
    is.numeric(records_per_file) &&
    length(records_per_file) == 1L &&
    !is.na(records_per_file) &&
    is.infinite(records_per_file) &&
    records_per_file > 0

  if (!finite_count && !infinite_count) {
    rlang::abort(
      "`records_per_file` must be a positive whole number or Inf.",
      class = "marcxmlr_argument_error"
    )
  }

  if (!dir.exists(dirname(file))) {
    rlang::abort(
      sprintf("Output directory does not exist: %s", dirname(file)),
      class = "marcxmlr_argument_error"
    )
  }

  invisible(NULL)
}

.writer_shard_paths <- function(file, n_shards) {
  filename <- basename(file)
  extension_start <- regexpr("\\.[^.]*$", filename)[[1L]]

  if (extension_start <= 1L) {
    stem <- filename
    extension <- ""
  } else {
    stem <- substr(filename, 1L, extension_start - 1L)
    extension <- substr(filename, extension_start, nchar(filename))
  }

  file.path(
    dirname(file),
    sprintf("%s-%05d%s", stem, seq_len(n_shards), extension)
  )
}

.writer_split_record_ids <- function(record_ids, records_per_file) {
  if (length(record_ids) == 0L) {
    return(list(integer()))
  }

  if (is.infinite(records_per_file)) {
    return(list(record_ids))
  }

  shard <-
    (seq_along(record_ids) - 1L) %/% as.integer(records_per_file) + 1L
  unname(split(record_ids, shard))
}

.writer_serialize_record <- function(parent, record_rows) {
  record_node <- xml2::xml_add_child(parent, "record")
  field_orders <- sort(unique(as.integer(record_rows$field_order)))

  for (field_order in field_orders) {
    field_rows <- record_rows[
      as.integer(record_rows$field_order) == field_order,
      ,
      drop = FALSE
    ]
    field_type <- field_rows$field_type[[1L]]

    if (field_type == "leader") {
      xml2::xml_add_child(record_node, "leader", field_rows$value[[1L]])
      next
    }

    if (field_type == "controlfield") {
      xml2::xml_add_child(
        record_node,
        "controlfield",
        field_rows$value[[1L]],
        tag = field_rows$tag[[1L]]
      )
      next
    }

    field_node <- xml2::xml_add_child(
      record_node,
      "datafield",
      tag = field_rows$tag[[1L]],
      ind1 = field_rows$ind1[[1L]],
      ind2 = field_rows$ind2[[1L]]
    )

    field_rows <- field_rows[
      order(as.integer(field_rows$subfield_order)),
      ,
      drop = FALSE
    ]

    for (j in seq_len(nrow(field_rows))) {
      xml2::xml_add_child(
        field_node,
        "subfield",
        field_rows$value[[j]],
        code = field_rows$subfield_code[[j]]
      )
    }
  }

  invisible(record_node)
}

.writer_write_collection_reference <- function(x, record_ids, file, pretty) {
  doc <- xml2::xml_new_root(
    "collection",
    xmlns = "http://www.loc.gov/MARC21/slim"
  )

  for (record_id in record_ids) {
    rows <- x[as.integer(x$record_id) == record_id, , drop = FALSE]
    .writer_serialize_record(doc, rows)
  }

  xml2::write_xml(
    doc,
    file,
    options = if (isTRUE(pretty)) "format" else character(),
    encoding = "UTF-8"
  )

  invisible(file)
}

.writer_native_columns <- function(x, record_ids) {
  record_id <- as.integer(x$record_id)
  keep <- record_id %in% record_ids
  idx <- which(keep)

  if (length(idx) > 0L) {
    record_rank <- match(record_id[idx], record_ids)
    field_rank <- as.integer(x$field_order[idx])
    subfield_rank <- ifelse(
      x$field_type[idx] == "datafield",
      as.integer(x$subfield_order[idx]),
      0L
    )

    idx <- idx[order(
      record_rank,
      field_rank,
      subfield_rank,
      seq_along(idx)
    )]
  }

  list(
    as.integer(x$record_id[idx]),
    x$field_type[idx],
    x$tag[idx],
    x$subfield_code[idx],
    x$value[idx],
    as.integer(x$field_order[idx]),
    x$ind1[idx],
    x$ind2[idx],
    as.integer(x$subfield_order[idx])
  )
}

.writer_write_collection_native <- function(x, record_ids, file, pretty) {
  columns <- .writer_native_columns(x, record_ids)

  .Call(
    C_marcxml_write_collection,
    columns,
    file,
    pretty
  )

  invisible(file)
}

# Native xmlTextWriter is the production serializer. Keep the R/xml2
# implementation above as the semantic reference and test oracle.
.writer_write_collection <- .writer_write_collection_native

.writer_temp_output_paths <- function(paths) {
  vapply(
    paths,
    function(path) {
      tempfile(
        pattern = paste0(".", basename(path), ".marcxmlr-"),
        tmpdir = dirname(path),
        fileext = ".tmp"
      )
    },
    character(1),
    USE.NAMES = FALSE
  )
}

.writer_write_outputs_staged <- function(
  x,
  chunks,
  paths,
  pretty,
  write_collection = .writer_write_collection
) {
  staged <- .writer_temp_output_paths(paths)
  committed <- character()
  success <- FALSE

  on.exit({
    staged_existing <- staged[file.exists(staged)]
    if (length(staged_existing) > 0L) {
      unlink(staged_existing, force = TRUE)
    }

    if (!success && length(committed) > 0L) {
      committed_existing <- committed[file.exists(committed)]
      if (length(committed_existing) > 0L) {
        unlink(committed_existing, force = TRUE)
      }
    }
  }, add = TRUE)

  for (i in seq_along(chunks)) {
    write_collection(
      x,
      record_ids = chunks[[i]],
      file = staged[[i]],
      pretty = pretty
    )
  }

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

  for (i in seq_along(paths)) {
    if (file.exists(paths[[i]])) {
      rlang::abort(
        sprintf(
          "Output file appeared while writing; staged outputs were not fully committed: %s",
          paths[[i]]
        ),
        class = "marcxmlr_output_exists",
        paths = paths[[i]]
      )
    }

    moved <- suppressWarnings(file.rename(staged[[i]], paths[[i]]))
    if (!isTRUE(moved)) {
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

#' Write a canonical MARC representation as MARCXML
#'
#' Serialize an in-memory canonical `marcxmlr` representation to MARCXML.
#' MARC record structure and values are preserved, but incidental XML
#' serialization details such as indentation, namespace-prefix spelling,
#' comments, entity spelling, and the original XML declaration are not.
#'
#' Records are written in ascending `record_id` order. Within each record,
#' `field_order` and `subfield_order` determine field and subfield ordering.
#' The occurrence columns are diagnostics only and are not used to construct
#' the XML.
#'
#' @param x A data frame or tibble containing the canonical 11-column
#'   `marcxmlr` representation.
#' @param file Output XML path. When `records_per_file` is finite, this path is
#'   used as the stem for deterministic shard names such as
#'   `catalogue-00001.xml`. Existing target files are not overwritten. Output
#'   files are staged before being committed so a serialization failure does
#'   not leave a partial shard family.
#' @param check Whether to emit warning-level canonical diagnostics before
#'   writing. Structurally ambiguous input is always rejected, including when
#'   `check = FALSE`.
#' @param pretty Whether to format the output XML with indentation.
#' @param records_per_file Maximum number of complete MARC records per output
#'   file. The default, `Inf`, writes one collection. A finite value writes
#'   numbered collection shards and never splits a record.
#'
#' @return Invisibly, a character vector containing the output path or paths.
#'
#' @export
#'
#' @examples
#' example_file <- system.file(
#'   "extdata", "example-marcxml.xml", package = "marcxmlr"
#' )
#' x <- read_marcxml(example_file)
#' out <- tempfile(fileext = ".xml")
#' write_marcxml(x, out)
write_marcxml <- function(
  x,
  file,
  check = TRUE,
  pretty = TRUE,
  records_per_file = Inf
) {
  .writer_validate_args(file, check, pretty, records_per_file)

  diagnostics <- .writer_diagnose_impl(
    x,
    include_warnings = isTRUE(check)
  )
  .writer_abort_errors(diagnostics)

  if (isTRUE(check)) {
    .writer_warn_warnings(diagnostics)
  }

  record_ids <- sort(unique(as.integer(x$record_id)))
  chunks <- .writer_split_record_ids(record_ids, records_per_file)

  paths <- if (is.infinite(records_per_file)) {
    file
  } else {
    .writer_shard_paths(file, length(chunks))
  }

  existing <- paths[file.exists(paths)]
  if (length(existing) > 0L) {
    rlang::abort(
      paste0(
        "Output file(s) already exist; no files were written: ",
        paste(existing, collapse = ", ")
      ),
      class = "marcxmlr_output_exists",
      paths = existing
    )
  }

  .writer_write_outputs_staged(
    x,
    chunks = chunks,
    paths = paths,
    pretty = pretty
  )

  invisible(paths)
}
