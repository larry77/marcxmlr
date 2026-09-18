.ensure_stream_record_namespace <- function(record_text, root_namespace) {
  # XML::saveXML() serializes a branch independently from its collection.
  # For the common MARCXML case, the record therefore loses the default
  # namespace inherited from <collection>. Avoid the more general regex-based
  # repair when we can restore that one known declaration directly.
  #
  # This is deliberately conservative. Anything other than an ordinary,
  # unprefixed <record ...> in the official MARC21 namespace is delegated to
  # the existing generic helper so its diagnostics and edge-case behaviour
  # remain authoritative.
  if (
    identical(root_namespace, .marcxml_namespace) &&
      is.character(record_text) &&
      length(record_text) == 1L &&
      !is.na(record_text) &&
      startsWith(record_text, "<record")
  ) {
    next_character <- substring(record_text, 8L, 8L)
    ordinary_start <- next_character %in% c(
      ">", " ", "\t", "\r", "\n"
    )

    # Search the complete serialized record rather than parsing the opening
    # tag in R. A namespace declaration anywhere makes us fall back to the
    # generic implementation. This can miss an optimization in unusual input,
    # but it cannot introduce a duplicate namespace declaration.
    opening_end <- regexpr(">", record_text, fixed = TRUE)[[1L]]

    if (ordinary_start && opening_end > 0L) {
      opening_tag <- substr(record_text, 1L, opening_end)

      if (!grepl("xmlns", opening_tag, fixed = TRUE)) {
        return(paste0(
          substr(record_text, 1L, opening_end - 1L),
          " xmlns=\"",
          root_namespace,
          "\"",
          substring(record_text, opening_end)
        ))
      }
    }
  }

  .ensure_record_namespace(record_text, root_namespace)
}

.marcxml_task_indices <- function(record_count, chunk_records) {
  starts <- seq.int(1L, record_count, by = chunk_records)

  purrr::map(starts, function(start) {
    seq.int(
      start,
      min(start + chunk_records - 1L, record_count)
    )
  })
}

.write_marcxml_parquet_task <- function(
  task,
  shared_records,
  first_record_id,
  compression
) {
  result <- .native_marcxml_records(
    shared_records,
    task$indices,
    first_record_id + task$indices - 1L
  )
  if (is.null(result)) {
    parsed <- purrr::map(task$indices, function(index) {
      parse_marcxml_record(
        record = shared_records[[index]],
        record_id = first_record_id + index - 1L
      )
    })
    result <- purrr::list_rbind(parsed)
  }
  temporary_path <- paste0(task$path, ".tmp-", Sys.getpid())

  on.exit(
    if (file.exists(temporary_path)) {
      unlink(temporary_path)
    },
    add = TRUE
  )

  arrow::write_parquet(
    result,
    sink = temporary_path,
    compression = compression
  )

  if (!file.rename(temporary_path, task$path)) {
    stop(
      sprintf("Could not move completed Parquet file to: %s", task$path),
      call. = FALSE
    )
  }

  list(
    records = length(task$indices),
    rows = nrow(result),
    path = task$path
  )
}

.native_marcxml_direct_to_parquet <- function(
  file,
  staging_dir,
  batch_records,
  compression,
  verbose,
  record_id_offset = 0L
) {
  if (!isTRUE(getOption("marcxmlr.native", TRUE)) ||
      !isTRUE(getOption("marcxmlr.native_stream", TRUE)) ||
      !isTRUE(getOption("marcxmlr.direct", TRUE)) ||
      !isTRUE(getOption("marcxmlr.direct_parquet", TRUE))) {
    return(NULL)
  }

  plan <- .native_marcxml_plan(
    file = file,
    mode = "stream"
  )

  if (!identical(plan$status, "supported")) {
    return(NULL)
  }

  on.exit(
    .native_marcxml_plan_close(plan),
    add = TRUE
  )

  info <- .native_marcxml_plan_info(plan)
  reader <- .native_marcxml_direct_reader_open(plan)

  on.exit(
    .native_marcxml_direct_reader_close(reader),
    add = TRUE
  )

  record_count <- 0L
  row_count <- 0
  batch_count <- 0L
  part_count <- 0L

  repeat {
    batch <- .native_marcxml_direct_reader_next(
      reader,
      batch_records = batch_records
    )

    if (is.null(batch)) {
      break
    }

    expected_first_record_id <- record_count + 1L

    if (batch$first_record_id != expected_first_record_id) {
      stop(
        sprintf(
          paste0(
            "Native MARCXML direct reader started a batch at record %s; ",
            "expected record %s."
          ),
          batch$first_record_id,
          expected_first_record_id
        ),
        call. = FALSE
      )
    }

    batch_count <- batch_count + 1L
    part_count <- part_count + 1L

    path <- file.path(
      staging_dir,
      sprintf("part-%06d.parquet", part_count)
    )

    if (record_id_offset > 0L && nrow(batch$data) > 0L) {
      batch$data$record_id <- batch$data$record_id + record_id_offset
    }

    arrow::write_parquet(
      batch$data,
      sink = path,
      compression = compression
    )

    record_count <- record_count + batch$records
    row_count <- row_count + nrow(batch$data)

    if (verbose) {
      message(sprintf(
        "Processed %s records; wrote %s Parquet file(s).",
        format(record_count, big.mark = ",", scientific = FALSE),
        format(part_count, big.mark = ",", scientific = FALSE)
      ))
    }

    rm(batch)
    invisible(gc(verbose = FALSE))
  }

  if (record_count != info$records_selected ||
      row_count != info$rows_selected) {
    stop(
      sprintf(
        paste0(
          "Native MARCXML direct Parquet totals disagree with the plan: ",
          "planned %s record(s)/%s row(s), produced %s record(s)/%s row(s)."
        ),
        info$records_selected,
        info$rows_selected,
        record_count,
        row_count
      ),
      call. = FALSE
    )
  }

  if (record_count == 0L) {
    arrow::write_parquet(
      .empty_marcxml(),
      sink = file.path(staging_dir, "part-000001.parquet"),
      compression = compression
    )
    part_count <- 1L
  }

  list(
    records = record_count,
    rows = row_count,
    batches = batch_count,
    parquet_files = part_count
  )
}

#' Convert a MARCXML collection to a Parquet dataset
#'
#' `marcxml_to_parquet()` streams complete MARCXML records from a collection,
#' parses them in bounded batches, and writes the canonical long representation
#' as a directory of Parquet files. It does not construct a DOM for the complete
#' XML document and does not materialize the complete parsed result in R.
#'
#' @param file One or more MARCXML collection paths, or glob patterns such as
#'   `"catalogue/*.xml"`. Glob matches are processed in sorted order.
#' @param output_dir Path for the new Parquet dataset directory. It must not
#'   already exist. The directory is published only after successful conversion.
#' @param batch_records Maximum number of records converted into one bounded
#'   canonical batch before writing. This bounds normal working memory, though
#'   an unusually large individual record can itself require substantial memory.
#' @param workers Number of local worker processes. The default, `1`, is
#'   sequential. Values greater than one require the optional parallel
#'   packages listed in `Suggests` and, with current dependency versions,
#'   R 4.3 or later.
#' @param chunk_records Number of records assigned to each parsing and writing
#'   task. `NULL` targets approximately two tasks per worker in each batch.
#' @param compression Parquet compression codec passed to
#'   [arrow::write_parquet()].
#' @param verbose Whether to report cumulative records and files after each
#'   completed batch.
#'
#' @return Invisibly, a tibble with one row per resolved input file containing
#'   the normalized input and output paths, record and row counts, number of
#'   batches, and number of Parquet files. Single-file input therefore retains
#'   the existing one-row return value. Parsed rows remain in the dataset
#'   directory.
#'
#' @details
#' The input must have a `collection` root in the official MARCXML namespace
#' (`http://www.loc.gov/MARC21/slim`) or no namespace. A standalone record can
#' be read with [read_marcxml()] but is not accepted by this collection
#' converter.
#'
#' With `workers = 1` and default `chunk_records = NULL`, supported ordinary
#' collections use a two-pass native libxml2 engine. The first pass validates
#' and counts the collection; the second fills bounded canonical batches
#' directly from `xmlTextReaderExpand()` nodes and writes them with `arrow`. No
#' record XML is serialized or reparsed on this path.
#'
#' For one input file, unsupported input, explicit `chunk_records`, and
#' parallel calls retain the established serialized-record/native or `XML`
#' event-stream implementations.
#'
#' When `file` resolves to multiple files, complete files are the unit of
#' parallel work. Each file is parsed by the existing sequential engine and
#' writes independent Parquet fragments. Global `record_id` values are assigned
#' deterministically in resolved file order, regardless of worker completion
#' order. XML/libxml2 external pointers are never sent to workers. Explicit
#' `chunk_records` is not supported for multi-file input.
#'
#' Parallel work is dispatched through a temporary `future.mirai` plan using
#' `futurize`; the caller's previous future plan is restored on exit.
#'
#' Each task writes a uniquely named temporary file and renames it only after a
#' successful Parquet write. All files are first written under a staging
#' directory beside `output_dir`; the completed directory is renamed into place
#' only after the XML input has been fully processed. Existing output is never
#' overwritten.
#'
#' Open the result with `arrow::open_dataset(output_dir)`. Opening a dataset is
#' lazy; calling `collect()` on the entire dataset will nevertheless materialize
#' every row in R memory.
#'
#' @examples
#' if (requireNamespace("XML", quietly = TRUE) &&
#'     requireNamespace("arrow", quietly = TRUE)) {
#'   example_file <- system.file(
#'     "extdata", "example-marcxml.xml", package = "marcxmlr"
#'   )
#'   output <- tempfile("marcxml-parquet-")
#'
#'   conversion <- marcxml_to_parquet(
#'     example_file,
#'     output_dir = output,
#'     workers = 1L,
#'     verbose = FALSE
#'   )
#'
#'   dataset <- arrow::open_dataset(output)
#'   conversion
#'   dataset
#'
#'   unlink(output, recursive = TRUE)
#' }
#'
#' @export
marcxml_to_parquet <- function(
  file,
  output_dir,
  batch_records = 5000L,
  workers = 1L,
  chunk_records = NULL,
  compression = "snappy",
  verbose = TRUE
) {
  input_files <- .resolve_marcxml_files(file)

  if (!is.character(output_dir) ||
      length(output_dir) != 1L ||
      is.na(output_dir) ||
      identical(output_dir, "")) {
    stop("`output_dir` must be one non-empty path.", call. = FALSE)
  }

  batch_records <- .validate_positive_whole_number(
    batch_records,
    "batch_records"
  )
  workers <- .validate_positive_whole_number(workers, "workers")

  if (!is.null(chunk_records)) {
    chunk_records <- .validate_positive_whole_number(
      chunk_records,
      "chunk_records"
    )
  }

  if (!is.character(compression) ||
      length(compression) != 1L ||
      is.na(compression) ||
      identical(compression, "")) {
    stop(
      "`compression` must be one non-empty character value.",
      call. = FALSE
    )
  }

  if (!is.logical(verbose) || length(verbose) != 1L || is.na(verbose)) {
    stop("`verbose` must be `TRUE` or `FALSE`.", call. = FALSE)
  }

  .require_marcxml_stream_packages(workers)

  if (length(input_files) == 1L && workers > 1L) {
    rlang::warn(
      c(
        "Parallel processing of a single MARCXML file may not improve performance.",
        "i" = paste0(
          "The optimized native sequential parser is often very fast, and ",
          "parallel overhead can outweigh the benefit."
        ),
        "i" = paste0(
          "Benchmark your own workload before relying on `workers > 1` ",
          "for single-file input."
        )
      ),
      .frequency = "regularly",
      .frequency_id = "marcxmlr-single-file-parallel"
    )
  }

  if (length(input_files) > 1L) {
    if (!is.null(chunk_records)) {
      stop(
        "`chunk_records` is not supported with multiple MARCXML files.",
        call. = FALSE
      )
    }

    return(.marcxml_to_parquet_multiple(
      input_files = input_files,
      output_dir = output_dir,
      batch_records = batch_records,
      workers = workers,
      compression = compression,
      verbose = verbose
    ))
  }

  input_file <- input_files[[1L]]
  record_id_offset <- .marcxml_internal_record_id_offset()
  output_dir <- path.expand(output_dir)
  output_name <- basename(output_dir)
  output_parent <- dirname(output_dir)

  if (output_name %in% c("", ".", "..")) {
    stop("`output_dir` must name a new dataset directory.", call. = FALSE)
  }

  if (!dir.exists(output_parent)) {
    if (!dir.create(output_parent, recursive = TRUE)) {
      stop(
        sprintf("Could not create output parent directory: %s", output_parent),
        call. = FALSE
      )
    }
  }

  output_parent <- normalizePath(
    output_parent,
    winslash = "/",
    mustWork = TRUE
  )
  output_dir <- file.path(output_parent, output_name)

  if (file.exists(output_dir)) {
    stop(
      sprintf("`output_dir` already exists: %s", output_dir),
      call. = FALSE
    )
  }

  staging_dir <- tempfile(
    pattern = paste0(".", output_name, "-incomplete-"),
    tmpdir = output_parent
  )

  if (!dir.create(staging_dir)) {
    stop(
      sprintf("Could not create staging directory: %s", staging_dir),
      call. = FALSE
    )
  }

  committed <- FALSE
  on.exit(
    if (!committed && dir.exists(staging_dir)) {
      unlink(staging_dir, recursive = TRUE, force = TRUE)
    },
    add = TRUE
  )

  # Prefer the direct bounded engine for the default sequential API. Explicit
  # chunking retains the established task/file partitioning semantics, and
  # parallel calls retain the current worker-safe serialized-record path.
  if (workers == 1L && is.null(chunk_records)) {
    direct_summary <- .native_marcxml_direct_to_parquet(
      file = input_file,
      staging_dir = staging_dir,
      batch_records = batch_records,
      compression = compression,
      verbose = verbose,
      record_id_offset = record_id_offset
    )

    if (!is.null(direct_summary)) {
      if (!file.rename(staging_dir, output_dir)) {
        stop(
          sprintf("Could not finalize the dataset directory: %s", output_dir),
          call. = FALSE
        )
      }

      committed <- TRUE

      return(invisible(tibble::tibble(
        input_file = input_file,
        output_dir = normalizePath(
          output_dir,
          winslash = "/",
          mustWork = TRUE
        ),
        records = direct_summary$records,
        rows = direct_summary$rows,
        batches = direct_summary$batches,
        parquet_files = direct_summary$parquet_files
      )))
    }
  }

  if (workers > 1L) {
    old_plan <- future::plan()
    on.exit(future::plan(old_plan), add = TRUE)
    future::plan(
      future.mirai::mirai_multisession,
      workers = workers
    )
  }

  state <- new.env(parent = emptyenv())
  state$records <- character(batch_records)
  state$batch_size <- 0L
  state$record_count <- 0L
  state$row_count <- 0
  state$part_count <- 0L
  state$batch_count <- 0L
  state$seen_root <- FALSE
  state$root_namespace <- NA_character_

  flush_batch <- function() {
    record_count <- state$batch_size

    if (record_count == 0L) {
      return(invisible(NULL))
    }

    records <- state$records[seq_len(record_count)]
    first_record_id <- as.integer(
      record_id_offset + state$record_count - record_count + 1L
    )

    # Release references held by the SAX state before processing the batch.
    state$records <- character(batch_records)
    state$batch_size <- 0L

    records_per_task <- if (is.null(chunk_records)) {
      target_tasks <- if (workers > 1L) workers * 2L else 1L
      max(1L, ceiling(record_count / target_tasks))
    } else {
      chunk_records
    }

    indices <- .marcxml_task_indices(record_count, records_per_task)
    part_ids <- state$part_count + seq_along(indices)
    paths <- file.path(
      staging_dir,
      sprintf("part-%06d.parquet", part_ids)
    )
    tasks <- purrr::map2(indices, paths, function(index, path) {
      list(indices = index, path = path)
    })

    if (workers > 1L) {
      shared_records <- mori::share(records)

      # Keep the worker call in a locally defined closure. `furrr` discovers
      # globals required by an anonymous mapping function from that function's
      # environment; passing the namespace-level task function directly can
      # omit newly added internal helpers such as `.native_marcxml_records`.
      task_results <- tasks |>
        purrr::map(function(task) {
          .write_marcxml_parquet_task(
            task,
            shared_records = shared_records,
            first_record_id = first_record_id,
            compression = compression
          )
        }) |>
        futurize::futurize()

      rm(shared_records)
    } else {
      task_results <- purrr::map(
        tasks,
        .write_marcxml_parquet_task,
        shared_records = records,
        first_record_id = first_record_id,
        compression = compression
      )
    }

    state$row_count <- state$row_count + sum(
      purrr::map_dbl(task_results, "rows")
    )
    state$part_count <- state$part_count + length(task_results)
    state$batch_count <- state$batch_count + 1L

    rm(records)
    invisible(gc(verbose = FALSE))

    if (verbose) {
      message(sprintf(
        "Processed %s records; wrote %s Parquet file(s).",
        format(state$record_count, big.mark = ",", scientific = FALSE),
        format(state$part_count, big.mark = ",", scientific = FALSE)
      ))
    }

    invisible(NULL)
  }

  native_streamed <- .native_marcxml_stream(
    input_file,
    batch_records,
    function(records) {
      record_count <- length(records)
      state$record_count <- state$record_count + record_count
      state$batch_size <- record_count
      state$records <- records
      flush_batch()
      invisible(NULL)
    }
  )

  if (!native_streamed) {
  record_branch <- function(node) {
    if (!state$seen_root) {
      stop(
        "Expected a MARCXML `<collection>` document.",
        call. = FALSE
      )
    }

    record_text <- XML::saveXML(
      node,
      indent = FALSE,
      prefix = character()
    )
    record_text <- .ensure_stream_record_namespace(
      record_text,
      state$root_namespace
    )

    state$record_count <- state$record_count + 1L
    state$batch_size <- state$batch_size + 1L
    state$records[[state$batch_size]] <- record_text

    if (state$batch_size == batch_records) {
      flush_batch()
    }

    invisible(NULL)
  }

  start_element <- function(name, attributes, namespace, namespaces) {
    namespace_uri <- if (
      length(namespace) == 0L || is.na(namespace[[1L]])
    ) {
      ""
    } else {
      unname(namespace[[1L]])
    }

    if (!state$seen_root) {
      if (name != "collection") {
        stop(
          "Expected a MARCXML `<collection>` document.",
          call. = FALSE
        )
      }

      if (!namespace_uri %in% c("", .marcxml_namespace)) {
        stop(
          sprintf(
            "Document root uses namespace <%s>; expected <%s> or no namespace.",
            namespace_uri,
            .marcxml_namespace
          ),
          call. = FALSE
        )
      }

      state$seen_root <- TRUE
      state$root_namespace <- namespace_uri
      return(invisible(NULL))
    }

    stop(
      "A MARCXML `<collection>` may contain only `<record>` elements.",
      call. = FALSE
    )
  }

  XML::xmlEventParse(
    input_file,
    handlers = list(.startElement = start_element),
    ignoreBlanks = FALSE,
    addContext = FALSE,
    useTagName = FALSE,
    asText = FALSE,
    trim = FALSE,
    useExpat = FALSE,
    replaceEntities = FALSE,
    validate = FALSE,
    saxVersion = 2L,
    branches = list(record = record_branch),
    useDotNames = TRUE
  )
  } else {
    state$seen_root <- TRUE
  }

  flush_batch()

  if (!state$seen_root) {
    stop(
      "The XML document has no MARCXML collection root.",
      call. = FALSE
    )
  }

  if (state$record_count == 0L) {
    empty_path <- file.path(staging_dir, "part-000001.parquet")
    arrow::write_parquet(
      .empty_marcxml(),
      sink = empty_path,
      compression = compression
    )
    state$part_count <- 1L
  }

  if (!file.rename(staging_dir, output_dir)) {
    stop(
      sprintf("Could not finalize the dataset directory: %s", output_dir),
      call. = FALSE
    )
  }

  committed <- TRUE
  summary <- tibble::tibble(
    input_file = input_file,
    output_dir = normalizePath(
      output_dir,
      winslash = "/",
      mustWork = TRUE
    ),
    records = state$record_count,
    rows = state$row_count,
    batches = state$batch_count,
    parquet_files = state$part_count
  )

  invisible(summary)
}
