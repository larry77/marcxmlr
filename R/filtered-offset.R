# C4: native Expat screening followed by direct libxml2 access to selected
# source byte ranges. Never used by the existing unfiltered code paths.

.validate_c4_filter <- function(filter_tag, filter_subfield, filter_equals,
                                chunk_records, on_marc_error, error_report) {
  if (is.null(filter_tag)) {
    if (!is.null(filter_subfield) || !is.null(filter_equals)) {
      stop("`filter_subfield` and `filter_equals` require `filter_tag`.",
           call. = FALSE)
    }
    return(FALSE)
  }
  if (!is.character(filter_tag) || length(filter_tag) != 1L ||
      is.na(filter_tag) || !grepl("^[0-9]{3}$", filter_tag)) {
    stop("`filter_tag` must be one three-digit MARC field tag.", call. = FALSE)
  }
  if (!is.null(filter_subfield) &&
      (!is.character(filter_subfield) || length(filter_subfield) != 1L ||
       is.na(filter_subfield) || nchar(filter_subfield, type = "bytes") != 1L)) {
    stop("`filter_subfield` must be one ASCII character.", call. = FALSE)
  }
  if (!is.null(filter_equals) &&
      (is.null(filter_subfield) || !is.character(filter_equals) ||
       length(filter_equals) != 1L || is.na(filter_equals))) {
    stop("`filter_equals` must be one string and requires `filter_subfield`.",
         call. = FALSE)
  }
  if (!is.null(chunk_records)) {
    stop("Filtering uses bounded native batches; `chunk_records` must be NULL.",
         call. = FALSE)
  }
  if (on_marc_error != "stop" || !is.null(error_report)) {
    stop("Offset filtering does not support MARC recovery or `error_report`.",
         call. = FALSE)
  }
  TRUE
}

.c4_check_encoding <- function(file) {
  con <- base::file(file, "rb")
  on.exit(close(con), add = TRUE)
  bytes <- readBin(con, "raw", n = 512L)
  if (any(bytes == as.raw(0))) {
    stop("Offset filtering supports only uncompressed UTF-8 XML.", call. = FALSE)
  }
  prefix <- rawToChar(bytes)
  declaration <- regmatches(
    prefix,
    regexec("^<\\?xml[^>]*\\bencoding\\s*=\\s*['\"]([^'\"]+)",
            prefix, perl = TRUE)
  )[[1L]]
  if (length(declaration) > 1L &&
      !toupper(declaration[[2L]]) %in% c("UTF-8", "UTF8")) {
    stop("Offset filtering supports only UTF-8 XML.", call. = FALSE)
  }
  invisible(TRUE)
}

.c4_screen_file <- function(file, filter_tag, filter_subfield, filter_equals) {
  # Screening is in the package's native shared library: no runtime compiler,
  # temporary executable, external process, or external TSV file.
  .c4_check_encoding(file)
  columns <- .Call(
    C_marcxml_offset_index,
    normalizePath(file, winslash = "/", mustWork = TRUE),
    filter_tag, filter_subfield, filter_equals
  )
  tibble::new_tibble(columns, nrow = length(columns[[1L]]))
}

.c4_read_filtered <- function(file, n_max, filter_tag,
                              filter_subfield, filter_equals) {
  offsets <- .c4_screen_file(file, filter_tag, filter_subfield, filter_equals)
  if (is.finite(n_max)) {
    offsets <- offsets[offsets$source_position <= n_max, , drop = FALSE]
  }
  batches <- list()
  .c4_visit_offsets(
    file, offsets,
    consume = function(batch) batches[[length(batches) + 1L]] <<- batch,
    .engine = "reader"
  )
  .bind_marcxml_results(batches)
}

.c4_write_filtered_one <- function(task, batch_records, compression) {
  if (!dir.create(task$output_dir)) {
    stop("Cannot create filtered worker output: ", task$output_dir, call. = FALSE)
  }
  rows <- 0
  batches <- 0L
  parts <- 0L
  records <- 0L
  if (nrow(task$offsets) > 0L) {
    .c4_visit_offsets(
      task$file, task$offsets,
      consume = function(batch) {
        ids <- as.double(batch$record_id) + task$record_id_offset
        if (any(ids > .Machine$integer.max)) {
          stop("Selected record IDs exceed the canonical integer range.",
               call. = FALSE)
        }
        batch$record_id <- as.integer(ids)
        parts <<- parts + 1L
        arrow::write_parquet(
          batch, sink = file.path(
            task$output_dir, sprintf("part-%06d.parquet", parts)
          ), compression = compression
        )
        batches <<- batches + 1L
        records <<- records + length(unique(batch$record_id))
        rows <<- rows + nrow(batch)
      },
      batch_records = batch_records,
      .engine = "reader"
    )
  }
  if (parts == 0L) {
    parts <- 1L
    arrow::write_parquet(
      .empty_marcxml(),
      sink = file.path(task$output_dir, "part-000001.parquet"),
      compression = compression
    )
  }
  if (records != nrow(task$offsets)) {
    stop("Filtered writer produced an unexpected number of records for ",
         task$file, call. = FALSE)
  }
  list(
    output_dir = task$output_dir,
    summary = tibble::tibble(
      input_file = task$file, records = records, rows = rows,
      batches = batches, parquet_files = parts
    )
  )
}

.c4_filtered_to_parquet <- function(input_files, output_dir, batch_records,
                                    workers, compression, verbose,
                                    filter_tag, filter_subfield, filter_equals) {
  if (length(input_files) == 1L && workers > 1L) {
    stop("Parallel filtering requires at least two MARCXML input files; ",
         "use `workers = 1L` for a single file.", call. = FALSE)
  }
  if (!requireNamespace("arrow", quietly = TRUE)) {
    stop("Install the `arrow` package to write Parquet.", call. = FALSE)
  }
  effective_workers <- min(workers, length(input_files))
  if (effective_workers > 1L) {
    .require_parallel_packages()
    with(
      future::plan(future.mirai::mirai_multisession,
                   workers = effective_workers),
      local = TRUE
    )
  }
  output <- .prepare_multifile_output(output_dir)
  staging <- tempfile(paste0(".", output$output_name, "-incomplete-"),
                      tmpdir = output$output_parent)
  if (!dir.create(staging)) {
    stop("Cannot create filtered Parquet staging directory.", call. = FALSE)
  }
  committed <- FALSE
  on.exit(if (!committed) unlink(staging, recursive = TRUE, force = TRUE),
          add = TRUE)
  if (verbose) {
    message(sprintf("Screening %d MARCXML file(s) with %d worker(s).",
                    length(input_files), effective_workers))
  }
  indexes <- purrr::map(input_files, function(path) {
    .c4_screen_file(path, filter_tag, filter_subfield, filter_equals)
  }) |>
    futurize::futurize(when = effective_workers > 1L)
  counts <- vapply(indexes, nrow, integer(1L))
  total <- sum(as.double(counts))
  if (total > .Machine$integer.max) {
    stop("Selected records exceed the canonical integer `record_id` range.",
         call. = FALSE)
  }
  id_offsets <- c(0, utils::head(cumsum(as.double(counts)), -1L))
  tasks <- lapply(seq_along(input_files), function(index) {
    list(file = input_files[[index]], offsets = indexes[[index]],
         record_id_offset = id_offsets[[index]],
         output_dir = file.path(staging, sprintf("file-%06d", index)))
  })
  rm(indexes)
  results <- purrr::map(tasks, function(task) {
    .c4_write_filtered_one(task, batch_records, compression)
  }) |>
    futurize::futurize(when = effective_workers > 1L)
  summaries <- purrr::map(results, "summary")
  summary <- purrr::list_rbind(summaries)
  part_count <- .finalize_multifile_parquet_parts(results, staging)
  if (part_count != sum(summary$parquet_files)) {
    stop("Filtered Parquet part count mismatch.", call. = FALSE)
  }
  if (!file.rename(staging, output$output_dir)) {
    stop("Cannot publish filtered Parquet output directory.", call. = FALSE)
  }
  committed <- TRUE
  summary$output_dir <- normalizePath(output$output_dir, winslash = "/",
                                      mustWork = TRUE)
  if (verbose) {
    message(sprintf("Selected %d record(s); wrote %d Parquet file(s).",
                    total, part_count))
  }
  invisible(summary)
}
