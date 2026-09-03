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
  parsed <- purrr::map(task$indices, function(index) {
    parse_marcxml_record(
      record = shared_records[[index]],
      record_id = first_record_id + index - 1L
    )
  })

  result <- purrr::list_rbind(parsed)
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

#' Convert a MARCXML collection to a Parquet dataset
#'
#' `marcxml_to_parquet()` streams complete MARCXML records from a collection,
#' parses them in bounded batches, and writes the canonical long representation
#' as a directory of Parquet files. It does not construct a DOM for the complete
#' XML document and does not materialize the complete parsed result in R.
#'
#' @param file Path to a MARCXML collection.
#' @param output_dir Path for the new Parquet dataset directory. It must not
#'   already exist. The directory is published only after successful conversion.
#' @param batch_records Maximum number of serialized records retained in a
#'   batch before parsing and writing. This bounds normal working memory, though
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
#' @return Invisibly, a one-row tibble containing the normalized input and
#'   output paths, record and row counts, number of batches, and number of
#'   Parquet files. Parsed rows remain in the dataset directory.
#'
#' @details
#' The input must have a `collection` root in the official MARCXML namespace
#' (`http://www.loc.gov/MARC21/slim`) or no namespace. A standalone record can
#' be read with [read_marcxml()] but is not accepted by this collection
#' converter.
#'
#' Complete records are serialized in the main process before parallel work.
#' This prevents XML external pointers from crossing process boundaries. With
#' multiple workers, record strings are exposed through `mori` shared memory,
#' and `futurize` dispatches `purrr` tasks through a temporary
#' `future.mirai` plan. The previous future plan is restored on exit.
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
  if (!is.character(file) || length(file) != 1L || is.na(file)) {
    stop("`file` must be one non-missing path.", call. = FALSE)
  }

  if (!file.exists(file)) {
    stop(
      sprintf("MARCXML file does not exist: %s", file),
      call. = FALSE
    )
  }

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
  input_file <- normalizePath(file, winslash = "/", mustWork = TRUE)
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
    first_record_id <- state$record_count - record_count + 1L

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

      task_results <- tasks |>
        purrr::map(
          .write_marcxml_parquet_task,
          shared_records = shared_records,
          first_record_id = first_record_id,
          compression = compression
        ) |>
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
    record_text <- .ensure_record_namespace(
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
