.empty_marc_error_report <- function() {
  tibble::tibble(
    source_file = character(),
    source_record = integer(),
    record_id = integer(),
    control_number = character(),
    reason = character(),
    record_xml = character()
  )
}

.validate_marc_error_report <- function(
  error_report,
  source_file,
  output_dir = NULL
) {
  valid <- is.character(error_report) &&
    length(error_report) == 1L &&
    !is.na(error_report) &&
    nzchar(error_report)

  if (!valid) {
    stop(
      paste0(
        "`error_report` must be one non-empty path when ",
        "`on_marc_error = \"skip\"`."
      ),
      call. = FALSE
    )
  }

  path <- path.expand(error_report)
  parent <- dirname(path)

  if (!dir.exists(parent)) {
    stop(
      sprintf("Error-report parent directory does not exist: %s", parent),
      call. = FALSE
    )
  }

  parent <- normalizePath(parent, winslash = "/", mustWork = TRUE)
  path <- file.path(parent, basename(path))

  if (file.exists(path)) {
    stop(
      sprintf("`error_report` already exists: %s", path),
      call. = FALSE
    )
  }

  source_file <- normalizePath(source_file, winslash = "/", mustWork = TRUE)

  if (identical(path, source_file)) {
    stop(
      "`error_report` must not overwrite the MARCXML input.",
      call. = FALSE
    )
  }

  if (!is.null(output_dir)) {
    expanded_output <- path.expand(output_dir)
    output_parent <- dirname(expanded_output)

    if (dir.exists(output_parent)) {
      output_path <- file.path(
        normalizePath(output_parent, winslash = "/", mustWork = TRUE),
        basename(expanded_output)
      )

      if (identical(path, output_path)) {
        stop(
          "`error_report` must not be the Parquet output directory.",
          call. = FALSE
        )
      }
    }
  }

  path
}

.write_marc_error_report <- function(diagnostics, error_report) {
  temporary <- tempfile(
    pattern = ".marcxmlr-errors-",
    tmpdir = dirname(error_report),
    fileext = ".csv"
  )

  on.exit(
    if (file.exists(temporary)) {
      unlink(temporary, force = TRUE)
    },
    add = TRUE
  )

  utils::write.csv(
    diagnostics,
    file = temporary,
    row.names = FALSE,
    na = ""
  )

  if (!file.rename(temporary, error_report)) {
    stop(
      sprintf("Could not publish MARC error report: %s", error_report),
      call. = FALSE
    )
  }

  invisible(error_report)
}

.warn_skipped_marc_records <- function(count, error_report) {
  if (count == 0L) {
    return(invisible(NULL))
  }

  warning(
    sprintf(
      paste0(
        "Skipped %s malformed MARC record(s). ",
        "Diagnostics were written to '%s'."
      ),
      format(count, big.mark = ",", scientific = FALSE),
      error_report
    ),
    call. = FALSE
  )

  invisible(NULL)
}


.native_marc_recovery_reason <- function(source_record, reason_code) {
  prefix <- sprintf("Record %d ", as.integer(source_record))

  detail <- switch(
    as.character(as.integer(reason_code)),
    "1" = "contains elements from another namespace.",
    "2" = "contains invalid nested elements.",
    "3" = "is empty.",
    "4" = "contains unsupported element(s).",
    "5" = "must begin with exactly one `<leader>`.",
    "6" = "contains a field without a `tag` attribute.",
    "7" = "contains a data field without an `ind1` attribute.",
    "8" = "contains a data field without an `ind2` attribute.",
    "9" = "contains a data field without any `<subfield>` elements.",
    "10" = "contains a data field with an unsupported child element.",
    "11" = "contains a subfield without a `code` attribute.",
    "contains unsupported MARCXML structure."
  )

  paste0(prefix, detail)
}

.native_marc_recovery_diagnostics <- function(
  info,
  source_file,
  record_id_offset = 0L
) {
  diagnostic <- info$diagnostics

  if (length(diagnostic$source_record) == 0L) {
    return(.empty_marc_error_report())
  }

  source_record <- as.integer(diagnostic$source_record)
  record_id <- source_record + as.integer(record_id_offset)

  tibble::tibble(
    source_file = rep.int(
      normalizePath(source_file, winslash = "/", mustWork = TRUE),
      length(source_record)
    ),
    source_record = source_record,
    record_id = record_id,
    control_number = diagnostic$control_number,
    reason = purrr::map2_chr(
      source_record,
      diagnostic$reason_code,
      .native_marc_recovery_reason
    ),
    record_xml = diagnostic$record_xml
  )
}

.stop_native_marc_recovery_decline <- function(plan) {
  reason <- if (is.character(plan$reason) &&
      length(plan$reason) == 1L &&
      !is.na(plan$reason)) {
    plan$reason
  } else {
    "unknown"
  }

  if (identical(reason, "xml_open")) {
    stop(
      "Native MARCXML recovery could not open the XML input.",
      call. = FALSE
    )
  }

  if (identical(reason, "xml_parse")) {
    stop(
      "XML parsing failed during native MARCXML recovery planning.",
      call. = FALSE
    )
  }

  stop(
    sprintf(
      "Native MARCXML recovery does not support this input (reason: %s).",
      reason
    ),
    call. = FALSE
  )
}

.read_marcxml_recover_native <- function(file, n_max, error_report) {
  plan <- .native_marcxml_recovery_plan(
    file = file,
    mode = "read",
    n_max = n_max
  )

  if (!identical(plan$status, "supported")) {
    .stop_native_marc_recovery_decline(plan)
  }

  on.exit(
    .native_marcxml_recovery_plan_close(plan),
    add = TRUE
  )

  info <- .native_marcxml_recovery_plan_info(plan)
  error_report <- .validate_marc_error_report(error_report, file)
  diagnostics <- .native_marc_recovery_diagnostics(info, file)

  output <- .empty_marcxml()

  if (info$records_valid > 0) {
    if (info$records_valid > .Machine$integer.max) {
      stop(
        "Native MARCXML recovery result has too many records for one in-memory read.",
        call. = FALSE
      )
    }

    reader <- .native_marcxml_recovery_reader_open(plan)
    on.exit(
      .native_marcxml_recovery_reader_close(reader),
      add = TRUE
    )

    batch <- .native_marcxml_recovery_reader_next(
      reader,
      batch_records = as.integer(info$records_valid)
    )

    if (is.null(batch)) {
      stop(
        "Native MARCXML recovery reader ended before its planned records.",
        call. = FALSE
      )
    }

    extra <- .native_marcxml_recovery_reader_next(
      reader,
      batch_records = 1L
    )

    if (!is.null(extra)) {
      stop(
        "Native MARCXML recovery reader produced more records than planned.",
        call. = FALSE
      )
    }

    output <- batch$data
  }

  .write_marc_error_report(diagnostics, error_report)
  .warn_skipped_marc_records(nrow(diagnostics), error_report)
  output
}

.read_marcxml_recover <- function(file, n_max, error_report) {
  .read_marcxml_recover_native(
    file = file,
    n_max = n_max,
    error_report = error_report
  )
}
